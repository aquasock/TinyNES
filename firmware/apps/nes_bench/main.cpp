// SPDX-License-Identifier: MIT
//
// nes_bench: runs the libretro FCEUmm core headless on a cartridge image
// built into the program, with a scripted controller, and times each
// retro_run against the NES frame period. Video and sound are not shown:
// checksums of them, taken outside the timed calls, are reported so that
// the AE350 run can be checked against the same program built for the PC.
//
// Report lines (identical in form on both builds):
//   TinyNES NES CORE=<core> ROM=<bytes> CRC=<crc32> START=<us>
//   TinyNES NES CACHE MICM=<csr> MDCM=<csr> I=<bytes>/<ways>/<line>
//       D=<bytes>/<ways>/<line> MCTL=<csr>             (AE350 only)
//   TinyNES NES F=<frame> AVG=<us> MAX=<us> BLIT=<us> VIDEO=<crc>
//       AUDIO=<crc>
//   TinyNES NES FRAMES=<n> AVG=<us> MIN=<us> MAX=<us> BLIT=<us> OVER=<n>
//       SPEED=<x.y>%
//   TinyNES NES VIDEO=<crc> AUDIO=<crc>
//
// The F= lines cover the frames since the last one. BLIT is the part of
// AVG that the core spends turning its 8-bit picture into the RGB565 or
// XRGB8888 frame it asked for: from its request for a frontend
// framebuffer, which is refused, to its video callback. MCTL is mcache_ctl, read back after the bits of
// NES_MCACHE (if built with MCACHE=<mask>) are set. VIDEO folds in every
// CHECK-th frame, AUDIO every frame. OVER counts frames slower than the
// NES frame period, SPEED is that period over the average frame time.
// On the PC, NES_DUMP=<dir> in the environment also saves the CHECK frames
// there as <frame>.ppm, to see where the input script has got to.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "libretro.h"

#ifdef __riscv
#include "tinynes.h"
#else
#include <ctime>
#endif

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

// The core's video and audio buffers outlive retro_run, so the callbacks
// only note where they are.
const void *frame_data;
unsigned frame_width, frame_height, frame_bytes = 4;
size_t frame_pitch;
const int16_t *audio_data;
size_t audio_frames;
uint16_t pad;
uint64_t blit_start, blit_time;

struct Press {
	unsigned first, count;
	uint16_t buttons;
};
Press presses[32];
unsigned press_count;

struct Button {
	const char *name;
	unsigned id;
};
const Button buttons[] = {
	{"a", RETRO_DEVICE_ID_JOYPAD_A},
	{"b", RETRO_DEVICE_ID_JOYPAD_B},
	{"select", RETRO_DEVICE_ID_JOYPAD_SELECT},
	{"start", RETRO_DEVICE_ID_JOYPAD_START},
	{"up", RETRO_DEVICE_ID_JOYPAD_UP},
	{"down", RETRO_DEVICE_ID_JOYPAD_DOWN},
	{"left", RETRO_DEVICE_ID_JOYPAD_LEFT},
	{"right", RETRO_DEVICE_ID_JOYPAD_RIGHT},
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
					p.buttons |= (uint16_t)(1u << b.id);
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

uint16_t pad_for(unsigned frame)
{
	uint16_t mask = 0;
	for (unsigned i = 0; i < press_count; i++)
		if (frame >= presses[i].first &&
		    frame - presses[i].first < presses[i].count)
			mask |= presses[i].buttons;
	return mask;
}

void log_cb(enum retro_log_level level, const char *fmt, ...)
{
	static const char *const names[] = {"DEBUG", "INFO", "WARN", "ERROR"};
	va_list ap;

	printf("%s %s ", NES_CORE, (unsigned)level < 4 ? names[level] : "?");
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
}

// The image as RetroArch describes it to cores that ask. FCEUmm reads the
// game from its path otherwise.
retro_game_info_ext game_ext = {
	"/rom.nes", nullptr, nullptr, "/", "rom", "nes", nullptr,
	nullptr, 0, false, false,
};

bool environment(unsigned cmd, void *data)
{
	switch (cmd & ~RETRO_ENVIRONMENT_EXPERIMENTAL) {
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
		static_cast<retro_log_callback *>(data)->log = log_cb;
		return true;
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
		switch (*static_cast<const retro_pixel_format *>(data)) {
		case RETRO_PIXEL_FORMAT_XRGB8888:
			frame_bytes = 4;
			return true;
		case RETRO_PIXEL_FORMAT_RGB565:
			frame_bytes = 2;
			return true;
		default:
			return false;
		}
	// No files: everything the core looks for there fails to open.
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
		*static_cast<const char **>(data) = "/";
		return true;
	case RETRO_ENVIRONMENT_GET_VARIABLE: {
		retro_variable *var = static_cast<retro_variable *>(data);
		var->value = nullptr;
		// The same power-on RAM every run, for repeatable checksums.
		if (!strcmp(var->key, "fceumm_ramstate"))
			var->value = "fill $00";
		return var->value != nullptr;
	}
	case RETRO_ENVIRONMENT_GET_GAME_INFO_EXT:
		*static_cast<const retro_game_info_ext **>(data) = &game_ext;
		return true;
	case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
		*static_cast<bool *>(data) = false;
		return true;
	case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS & ~RETRO_ENVIRONMENT_EXPERIMENTAL:
		return true;
	case RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER &
	    ~RETRO_ENVIRONMENT_EXPERIMENTAL:
		blit_start = ticks();
		return false;
	default:
		return false;
	}
}

void video_refresh(const void *data, unsigned width, unsigned height,
		   size_t pitch)
{
	frame_data = data;
	frame_width = width;
	frame_height = height;
	frame_pitch = pitch;
	if (blit_start)
		blit_time = ticks() - blit_start;
}

void audio_sample(int16_t, int16_t) {}

size_t audio_sample_batch(const int16_t *data, size_t frames)
{
	audio_data = data;
	audio_frames = frames;
	return frames;
}

void input_poll() {}

int16_t input_state(unsigned port, unsigned device, unsigned, unsigned id)
{
	if (port != 0 || device != RETRO_DEVICE_JOYPAD)
		return 0;
	if (id == RETRO_DEVICE_ID_JOYPAD_MASK)
		return (int16_t)pad;
	return (int16_t)(pad >> id & 1);
}

#ifndef __riscv
void dump_frame(const char *dir, unsigned frame)
{
	char path[512];
	snprintf(path, sizeof path, "%s/%05u.ppm", dir, frame);
	FILE *out = fopen(path, "wb");
	if (!out)
		return;
	fprintf(out, "P6 %u %u 255\n", frame_width, frame_height);
	for (unsigned y = 0; y < frame_height; y++) {
		const uint8_t *row =
			static_cast<const uint8_t *>(frame_data) + y * frame_pitch;
		for (unsigned x = 0; x < frame_width; x++) {
			uint8_t rgb[3];
			if (frame_bytes == 4) {
				uint32_t p;
				memcpy(&p, row + x * 4, 4);
				rgb[0] = (uint8_t)(p >> 16);
				rgb[1] = (uint8_t)(p >> 8);
				rgb[2] = (uint8_t)p;
			} else {
				uint16_t p;
				memcpy(&p, row + x * 2, 2);
				rgb[0] = (uint8_t)((p >> 11) * 255 / 31);
				rgb[1] = (uint8_t)((p >> 5 & 63) * 255 / 63);
				rgb[2] = (uint8_t)((p & 31) * 255 / 31);
			}
			fwrite(rgb, 1, 3, out);
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
#endif

} // namespace

int main()
{
	const size_t rom_size = (size_t)(nes_rom_end - nes_rom);
	const unsigned frames = NES_FRAMES;

	crc_init();
	if (!parse_input(NES_INPUT)) {
		printf("TinyNES NES BAD INPUT %s\n", NES_INPUT);
		return 2;
	}

	retro_set_environment(environment);
	retro_set_video_refresh(video_refresh);
	retro_set_audio_sample(audio_sample);
	retro_set_audio_sample_batch(audio_sample_batch);
	retro_set_input_poll(input_poll);
	retro_set_input_state(input_state);

#if defined(__riscv) && defined(NES_MCACHE)
	__asm__ volatile("csrs 0x7ca, %0" : : "r"((uint32_t)NES_MCACHE));
#endif

	uint64_t start = ticks();
	retro_init();
	retro_game_info game = {"/rom.nes", nes_rom, rom_size, nullptr};
	game_ext.data = nes_rom;
	game_ext.size = rom_size;
	bool loaded = retro_load_game(&game);
	start = ticks() - start;
	if (!loaded) {
		printf("TinyNES NES LOAD FAILED\n");
		return 1;
	}

	retro_system_av_info av;
	retro_get_system_av_info(&av);
	// The NES frame period, from the core's own frame rate.
	const uint64_t budget = (uint64_t)((double)tick_hz / av.timing.fps);

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
#endif

#ifndef __riscv
	const char *dump = getenv("NES_DUMP");
#endif
	uint32_t video_crc = 0, audio_crc = 0;
	uint64_t total = 0, low = UINT64_MAX, high = 0, part = 0, part_high = 0;
	uint64_t blit_total = 0, part_blit = 0;
	unsigned over = 0, part_frames = 0;

	for (unsigned f = 0; f < frames; f++) {
		pad = pad_for(f);
		frame_data = nullptr;
		audio_frames = 0;
		blit_start = blit_time = 0;

		uint64_t t = ticks();
		retro_run();
		t = ticks() - t;

		total += t;
		part += t;
		blit_total += blit_time;
		part_blit += blit_time;
		part_frames++;
		if (t < low)
			low = t;
		if (t > high)
			high = t;
		if (t > part_high)
			part_high = t;
		if (t > budget)
			over++;

		audio_crc = crc_update(audio_crc, audio_data,
				       audio_frames * 2 * sizeof(int16_t));
		if ((f + 1) % NES_CHECK == 0 && frame_data) {
			const uint8_t *row = static_cast<const uint8_t *>(frame_data);
			for (unsigned y = 0; y < frame_height; y++, row += frame_pitch)
				video_crc = crc_update(video_crc, row,
						       frame_width * frame_bytes);
#ifndef __riscv
			if (dump)
				dump_frame(dump, f + 1);
#endif
		}
		if ((f + 1) % NES_REPORT == 0 || f + 1 == frames) {
			printf("TinyNES NES F=%u AVG=%llu MAX=%llu BLIT=%llu "
			       "VIDEO=%08lx AUDIO=%08lx\n", f + 1,
			       (unsigned long long)to_us(part / part_frames),
			       (unsigned long long)to_us(part_high),
			       (unsigned long long)to_us(part_blit / part_frames),
			       (unsigned long)video_crc, (unsigned long)audio_crc);
			part = part_high = part_blit = 0;
			part_frames = 0;
		}
	}

	const uint64_t avg = total / frames;
	const unsigned speed = (unsigned)(budget * 1000u / avg);
	printf("TinyNES NES FRAMES=%u AVG=%llu MIN=%llu MAX=%llu BLIT=%llu "
	       "OVER=%u SPEED=%u.%u%%\n", frames, (unsigned long long)to_us(avg),
	       (unsigned long long)to_us(low), (unsigned long long)to_us(high),
	       (unsigned long long)to_us(blit_total / frames), over,
	       speed / 10, speed % 10);
	printf("TinyNES NES VIDEO=%08lx AUDIO=%08lx\n", (unsigned long)video_crc,
	       (unsigned long)audio_crc);

	retro_unload_game();
	retro_deinit();
#if defined(__riscv) && defined(NES_MCACHE)
	__asm__ volatile("csrc 0x7ca, %0" : : "r"((uint32_t)NES_MCACHE));
#endif
	return 0;
}
