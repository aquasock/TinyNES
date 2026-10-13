// SPDX-License-Identifier: MIT
//
// nes_bench: runs the FCEUmm NES emulator on a cartridge image built into
// the program, with a scripted controller, and times each emulated frame
// against the NES frame period. It drives FCEUmm's emulation core directly,
// in place of FCEUmm's libretro driver, so the core's own 8-bit picture is
// the output: on the AE350 the core draws each frame straight into the
// SDRAM frame buffer not being shown (fpga/ae350_soc/video.sv), FCEUmm's
// palette goes to the video unit's palette and each line's colour emphasis
// to its emphasis registers, and the frame is shown on HDMI at the next
// vertical blank. Sound is emulated but not played. Checksums of the
// picture and sound, taken outside the timed calls, are reported so that
// the AE350 run can be checked against the same program built for the PC.
//
// Report lines (identical in form on both builds):
//   TinyNES NES CORE=<core> ROM=<bytes> CRC=<crc32> START=<us>
//   TinyNES NES CACHE MICM=<csr> MDCM=<csr> I=<bytes>/<ways>/<line>
//       D=<bytes>/<ways>/<line> MCTL=<csr>             (AE350 only)
//   TinyNES NES F=<frame> AVG=<us> MAX=<us> SHOW=<us> VIDEO=<crc>
//       AUDIO=<crc>
//   TinyNES NES FRAMES=<n> AVG=<us> MIN=<us> MAX=<us> SHOW=<us> OVER=<n>
//       SPEED=<x.y>% LATE=<n> MISSED=<n>
//   TinyNES NES VIDEO=<crc> AUDIO=<crc>
//
// The F= lines cover the frames since the last one. AVG, MIN and MAX time
// FCEUI_Emulate alone. SHOW is the mean time to hand a frame to the video
// unit: writing the D-cache back and any changed emphasis, and asking for
// the buffer; on the PC it is 0. On the AE350 each frame starts once the
// one before is on screen, so the picture changes at 60 frames a second
// while the emulation keeps up. MISSED counts frames shown a vertical blank
// later than the one after they were asked for, LATE the lines the video
// unit showed before its SDRAM fetch had finished; both are 0 on the PC.
// MCTL is mcache_ctl, read back after the bits of NES_MCACHE (if built with
// MCACHE=<mask>) are set. VIDEO folds in the picture and each line's
// emphasis of every CHECK-th frame, AUDIO every frame's samples. OVER
// counts frames slower than the NES frame period, SPEED is that period
// over the average frame time. On the PC, NES_DUMP=<dir> in the environment
// also saves the CHECK frames there as <frame>.ppm.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifdef __riscv
#include "tinynes.h"
#else
#include <ctime>
#endif

// FCEUmm's core (third_party/fceumm/src/driver.h, fceu.h, video.c, fceu.c).
extern "C" {
struct FCEUGI;
int FCEUI_Initialize(void);
FCEUGI *FCEUI_LoadGame(const char *name, const uint8_t *databuf, size_t size,
		       void (*post_load)(void));
void FCEUI_Emulate(uint8_t **xbuf, int32_t **sound, int32_t *sound_size, int skip);
void FCEUI_SetInput(int port, int type, void *ptr, int attrib);
void FCEUI_Sound(int rate);
void FCEUI_SetSoundVolume(uint32_t volume);
void FCEUI_CloseGame(void);
void FCEUI_Kill(void);
extern uint8_t *XBuf, *XDBuf;
extern int option_ramstate;
}

namespace {
const int SI_GAMEPAD = 1;
const uint8_t JOY_A = 0x01, JOY_B = 0x02, JOY_SELECT = 0x04, JOY_START = 0x08,
	      JOY_UP = 0x10, JOY_DOWN = 0x20, JOY_LEFT = 0x40, JOY_RIGHT = 0x80;
// FCEUmm's libretro driver's defaults, which these runs keep.
const int SOUND_RATE = 48000;
const uint32_t SOUND_VOLUME = 150;
// The NES frame period: FCEUmm's NTSC rate of 39375000 / 655171 Hz.
const double NES_FPS = 39375000.0 / 655171.0;
const unsigned WIDTH = 256, HEIGHT = 240;
// The PPU writes lines 0 to 240 of XBuf (240 for the lines it does not
// show), each up to 272 bytes from its start, so a frame needs 61,712
// bytes, which fits a 64 KiB frame-buffer slot.
const size_t XBUF_BYTES = 241 * 256 + 16;
} // namespace

// What FCEUmm's core needs from its driver, as its libretro driver has it.
extern "C" {
unsigned overclock_enabled = 0;
unsigned overclocked = 0;
unsigned skip_7bit_overclocking = 1;
unsigned totalscanlines = 0;
unsigned normal_scanlines = 240;
unsigned extrascanlines = 0;
unsigned vblankscanlines = 0;
unsigned dendy = 0;
unsigned swapDuty = 0;

const char *GetKeyboard(void) { return ""; }
void FCEUD_SetPalette(uint16_t index, uint8_t r, uint8_t g, uint8_t b);
void FCEUD_PrintError(const char *s) { printf("fceumm ERROR %s\n", s); }
void FCEUD_Message(const char *s) { printf("fceumm %s", s); }
void FCEUD_DispMessage(int, unsigned, const char *s) { printf("fceumm %s\n", s); }
}

#define NES_CORE "fceumm"
#ifndef NES_FRAMES
#define NES_FRAMES 1800
#endif
#ifndef NES_CHECK
#define NES_CHECK 60
#endif
#ifndef NES_REPORT
#define NES_REPORT 120
#endif
// <first frame>+<frames>=<button>[,<button>...], space separated. The
// default starts Castlevania, waits out the walk to the gate and then
// walks right through the first stage, whipping and jumping.
#ifndef NES_INPUT
#define NES_INPUT "120+6=start 720+1080=right " \
	"800+4=b 900+4=b 1000+4=a 1100+4=b 1200+4=b 1300+4=a " \
	"1400+4=b 1500+4=b 1600+4=a 1700+4=b"
#endif

extern "C" const unsigned char nes_rom[], nes_rom_end[];

namespace {

#ifdef __riscv
const uint64_t tick_hz = TN_CORE_HZ;
uint64_t ticks() { return tn_cycles64(); }
#else
const uint64_t tick_hz = 1000000000u;
uint64_t ticks()
{
	timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * tick_hz + (uint64_t)ts.tv_nsec;
}
#endif

uint64_t to_us(uint64_t t) { return t * 1000000u / tick_hz; }

uint32_t crc_table[256];

void crc_init()
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (c & 1 ? 0xedb88320u : 0);
		crc_table[i] = c;
	}
}

uint32_t crc_update(uint32_t crc, const void *data, size_t len)
{
	const uint8_t *p = static_cast<const uint8_t *>(data);
	crc = ~crc;
	while (len--)
		crc = crc_table[(crc ^ *p++) & 0xff] ^ (crc >> 8);
	return ~crc;
}

// The palette as FCEUmm last set it, for the PC's frame dumps.
uint8_t palette[1024][3];

struct Press {
	unsigned first, count;
	uint8_t buttons;
};
Press presses[32];
unsigned press_count;

struct Button {
	const char *name;
	uint8_t bit;
};
const Button buttons[] = {
	{"a", JOY_A}, {"b", JOY_B}, {"select", JOY_SELECT}, {"start", JOY_START},
	{"up", JOY_UP}, {"down", JOY_DOWN}, {"left", JOY_LEFT}, {"right", JOY_RIGHT},
};

bool parse_input(const char *s)
{
	while (*s) {
		while (*s == ' ')
			s++;
		if (!*s)
			break;
		if (press_count == sizeof presses / sizeof presses[0])
			return false;
		Press &p = presses[press_count++];
		char *end;
		p.first = (unsigned)strtoul(s, &end, 10);
		if (*end != '+')
			return false;
		p.count = (unsigned)strtoul(end + 1, &end, 10);
		if (*end != '=')
			return false;
		s = end + 1;
		p.buttons = 0;
		do {
			if (*s == ',')
				s++;
			size_t len = strcspn(s, ", ");
			bool found = false;
			for (const Button &b : buttons) {
				if (strlen(b.name) == len && !strncmp(b.name, s, len)) {
					p.buttons |= b.bit;
					found = true;
				}
			}
			if (!found)
				return false;
			s += len;
		} while (*s == ',');
	}
	return true;
}

uint8_t pad_for(unsigned frame)
{
	uint8_t mask = 0;
	for (unsigned i = 0; i < press_count; i++)
		if (frame >= presses[i].first &&
		    frame - presses[i].first < presses[i].count)
			mask |= presses[i].buttons;
	return mask;
}

#ifdef __riscv
uint8_t *frame_buffer(unsigned b) { return TN_VIDEO_FB(b); }
#else
uint8_t host_buffers[2][65536];
uint8_t *frame_buffer(unsigned b) { return host_buffers[b]; }

void dump_frame(const char *dir, unsigned frame, const uint8_t *pixels,
		const uint8_t *emphasis)
{
	char path[512];
	snprintf(path, sizeof path, "%s/%05u.ppm", dir, frame);
	FILE *out = fopen(path, "wb");
	if (!out)
		return;
	fprintf(out, "P6 %u %u 255\n", WIDTH, HEIGHT);
	for (unsigned y = 0; y < HEIGHT; y++) {
		unsigned e = emphasis[y * 256u] & 7;
		for (unsigned x = 0; x < WIDTH; x++) {
			unsigned p = pixels[y * 256u + x];
			unsigned i = e ? 256u + (e << 6) + (p & 63) : p;
			fwrite(palette[i], 1, 3, out);
		}
	}
	fclose(out);
}
#endif

#ifdef __riscv
// micm_cfg (0xfc0) and mdcm_cfg (0xfc1): sets in bits 2:0 (with SETH, bit
// 24), ways - 1 in bits 5:3, line size in bits 8:6 (0 for no cache).
void print_cache(const char *name, uint32_t cfg)
{
	unsigned set = cfg & 7, way = (cfg >> 3 & 7) + 1, sz = cfg >> 6 & 7;
	unsigned sets = cfg >> 24 & 1 ? 32u >> set : 64u << set;
	unsigned line = sz ? 4u << sz : 0;

	printf(" %s=%u/%u/%u", name, line ? sets * way * line : 0, way, line);
}

// The emphasis each line of each buffer was last given.
uint8_t shown_emphasis[2][HEIGHT];
#endif

} // namespace

extern "C" void FCEUD_SetPalette(uint16_t index, uint8_t r, uint8_t g, uint8_t b)
{
	if (index >= 1024)
		return;
	palette[index][0] = r;
	palette[index][1] = g;
	palette[index][2] = b;
#ifdef __riscv
	if (index < TN_VIDEO_PALETTE_SIZE)
		TN_VIDEO_PALETTE(index) = (uint32_t)r << 16 | (uint32_t)g << 8 | b;
#endif
}

int main()
{
	const size_t rom_size = (size_t)(nes_rom_end - nes_rom);
	const unsigned frames = NES_FRAMES;
	const uint64_t budget = (uint64_t)((double)tick_hz / NES_FPS);

	crc_init();
	if (!parse_input(NES_INPUT)) {
		printf("TinyNES NES BAD INPUT %s\n", NES_INPUT);
		return 2;
	}

#if defined(__riscv) && defined(NES_MCACHE)
	__asm__ volatile("csrs 0x7ca, %0" : : "r"((uint32_t)NES_MCACHE));
#endif

	uint64_t start = ticks();
	// The same power-on RAM every run (FCEUmm's "fill $00"), for
	// repeatable checksums.
	option_ramstate = 1;
	if (!FCEUI_Initialize()) {
		printf("TinyNES NES INIT FAILED\n");
		return 1;
	}
	FCEUI_SetSoundVolume(SOUND_VOLUME);
	FCEUI_Sound(SOUND_RATE);
	if (!FCEUI_LoadGame("rom.nes", nes_rom, rom_size, nullptr)) {
		printf("TinyNES NES LOAD FAILED\n");
		return 1;
	}
	uint32_t joypads = 0;
	FCEUI_SetInput(0, SI_GAMEPAD, &joypads, 0);
	FCEUI_SetInput(1, SI_GAMEPAD, &joypads, 0);
	start = ticks() - start;

	printf("TinyNES NES CORE=%s ROM=%u CRC=%08lx START=%llu\n", NES_CORE,
	       (unsigned)rom_size,
	       (unsigned long)crc_update(0, nes_rom, rom_size),
	       (unsigned long long)to_us(start));
#ifdef __riscv
	uint32_t micm, mdcm;
	__asm__ volatile("csrr %0, 0xfc0" : "=r"(micm));
	__asm__ volatile("csrr %0, 0xfc1" : "=r"(mdcm));
	printf("TinyNES NES CACHE MICM=%08lx MDCM=%08lx", (unsigned long)micm,
	       (unsigned long)mdcm);
	print_cache("I", micm);
	print_cache("D", mdcm);
	uint32_t mctl;
	__asm__ volatile("csrr %0, 0x7ca" : "=r"(mctl));
	printf(" MCTL=%08lx\n", (unsigned long)mctl);

	// Every line's emphasis set once, then only changes are written.
	for (unsigned b = 0; b < 2; b++)
		for (unsigned y = 0; y < HEIGHT; y++)
			TN_VIDEO_EMPHASIS(b, y) = 0;
	const uint32_t late0 = TN_VIDEO_LATE;
	unsigned missed = 0;
#else
	const char *dump = getenv("NES_DUMP");
#endif
	// The core draws into the frame buffers; its own XBuf goes back
	// before it is freed.
	uint8_t *const core_xbuf = XBuf;
	static_assert(XBUF_BYTES <= 65536, "a frame must fit its buffer slot");

	uint32_t video_crc = 0, audio_crc = 0;
	uint64_t total = 0, low = UINT64_MAX, high = 0, part = 0, part_high = 0;
	uint64_t show_total = 0, part_show = 0;
	unsigned over = 0, part_frames = 0, back = 1;

	for (unsigned f = 0; f < frames; f++) {
		joypads = pad_for(f);
		XBuf = frame_buffer(back);

		uint8_t *pixels;
		int32_t *sound;
		int32_t sound_size = 0;
		uint64_t t = ticks();
		FCEUI_Emulate(&pixels, &sound, &sound_size, 0);
		t = ticks() - t;

		uint64_t s = ticks();
#ifdef __riscv
		tn_dcache_wbinval();
		for (unsigned y = 0; y < HEIGHT; y++) {
			uint8_t e = XDBuf[y * 256u] & 7;
			if (e != shown_emphasis[back][y]) {
				TN_VIDEO_EMPHASIS(back, y) = e;
				shown_emphasis[back][y] = e;
			}
		}
		const uint32_t vbl = TN_VIDEO_FRAMES;
		TN_VIDEO_CTRL = TN_VIDEO_ENABLE | (back ? TN_VIDEO_BUFFER : 0);
		s = ticks() - s;
		// The next frame starts once this one is on screen, so that it
		// never draws into a buffer waiting to be shown.
		const uint32_t want = TN_VIDEO_SHOWING | (back ? TN_VIDEO_BUFFER : 0);
		while ((TN_VIDEO_STATUS & (TN_VIDEO_SHOWING | TN_VIDEO_BUFFER)) != want)
			;
		if (TN_VIDEO_FRAMES - vbl > 1)
			missed++;
#else
		s = 0;
#endif
		back ^= 1;

		total += t;
		part += t;
		show_total += s;
		part_show += s;
		part_frames++;
		if (t < low)
			low = t;
		if (t > high)
			high = t;
		if (t > part_high)
			part_high = t;
		if (t > budget)
			over++;

		audio_crc = crc_update(audio_crc, sound, (size_t)sound_size * sizeof(int32_t));
		if ((f + 1) % NES_CHECK == 0) {
			video_crc = crc_update(video_crc, pixels, WIDTH * HEIGHT);
			for (unsigned y = 0; y < HEIGHT; y++)
				video_crc = crc_update(video_crc, XDBuf + y * 256u, 1);
#ifndef __riscv
			if (dump)
				dump_frame(dump, f + 1, pixels, XDBuf);
#endif
		}
		if ((f + 1) % NES_REPORT == 0 || f + 1 == frames) {
			printf("TinyNES NES F=%u AVG=%llu MAX=%llu SHOW=%llu "
			       "VIDEO=%08lx AUDIO=%08lx\n", f + 1,
			       (unsigned long long)to_us(part / part_frames),
			       (unsigned long long)to_us(part_high),
			       (unsigned long long)to_us(part_show / part_frames),
			       (unsigned long)video_crc, (unsigned long)audio_crc);
			part = part_high = part_show = 0;
			part_frames = 0;
		}
	}

#ifdef __riscv
	const unsigned late = TN_VIDEO_LATE - late0;
#else
	const unsigned late = 0, missed = 0;
#endif
	const uint64_t avg = total / frames;
	const unsigned speed = (unsigned)(budget * 1000u / avg);
	printf("TinyNES NES FRAMES=%u AVG=%llu MIN=%llu MAX=%llu SHOW=%llu "
	       "OVER=%u SPEED=%u.%u%% LATE=%u MISSED=%u\n", frames,
	       (unsigned long long)to_us(avg), (unsigned long long)to_us(low),
	       (unsigned long long)to_us(high),
	       (unsigned long long)to_us(show_total / frames), over, speed / 10,
	       speed % 10, late, missed);
	printf("TinyNES NES VIDEO=%08lx AUDIO=%08lx\n", (unsigned long)video_crc,
	       (unsigned long)audio_crc);

	// The last frame stays on screen; the core frees only its own buffer.
	XBuf = core_xbuf;
	FCEUI_CloseGame();
	FCEUI_Kill();
#if defined(__riscv) && defined(NES_MCACHE)
	__asm__ volatile("csrc 0x7ca, %0" : : "r"((uint32_t)NES_MCACHE));
#endif
	return late ? 1 : 0;
}
