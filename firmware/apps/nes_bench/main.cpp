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
//   TinyNES NES PALETTE=<name>
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
// also saves the CHECK frames there as <frame>.ppm. PALETTE names the
// palette the game is shown in: fceumm, the core's own, or one of the
// presets of FCEUmm's libretro driver (tools/gen_fceumm_palettes.py),
// chosen by NES_PALETTE here and by the host under PLAY=1.
//
// Built with PLAY=1 (AE350 only) it is a playable NES instead. It takes its
// cartridge at start: it prints
//   TinyNES WANT <address> <bytes>
// and receives one more image in the boot ROM's load protocol
// (firmware/boot/load.c, tinynes.h) at that address, holding "TNR1", the
// cartridge's length and the .nes file, from tools/load_ae350.py --file or
// TinyTang's ae350run. Once it has the cartridge it prints
//   TinyNES LINK
// and turns the UART to link mode (desk_link.sv, tinynes.h): from then on
// its text goes out in TinyTang's frames, and TinyTang draws TinyDesk's layer
// over the game, which a tap of HOME on controller 1 or F12 shows and hides.
// The game keeps running behind the desktop, with sound, but gets no
// controller input while it is shown. The Wii
// Classic Controllers on PMOD0's first two buses (fpga/ae350_soc/wii_pads.sv)
// are players 1 and 2 in place of the script, the game runs until HOME and
// SELECT are held together on either controller, and the report lines come
// once a minute and at the end:
//   TinyNES NES PLAY PAD1=<state> PAD2=<state> SOUND=<Hz>
// where <state> is classic, other or absent. A controller that is absent or
// not a Classic Controller reads as nothing pressed. The sound plays on the
// Pmod I2S2 on PMOD1 (fpga/ae350_soc/i2s_out.sv), FCEUmm's mono sample in
// both channels. The DAC takes 75 MHz / 1536 = 48,828.125 pairs a second,
// 813.8 per 60 Hz HDMI frame, while the game runs one NES frame per HDMI
// frame, so FCEUmm is run at that rate times 60.0988 / 60, 48,909 Hz, to
// make as many samples a frame as are played. The FIFO starts with 800
// pairs of silence, and at the start of each frame its level is steered
// toward AUDIO_TARGET by repeating or dropping one sample. The end adds
//   TinyNES NES AUDIO UNDER=<n> DROPS=<n> LEVEL=<min>-<max> ADJUST=+<n>/-<n>
//       PUSH=<us> PUSHED=<pairs> PLAYED=<pairs> VBL=<frames>
// UNDER counts frames the DAC found the FIFO empty, DROPS samples sent to a
// full FIFO, LEVEL the range of the level at frame starts, ADJUST the
// samples repeated and dropped, PUSH the mean time to send a frame's sound,
// and PUSHED, PLAYED and VBL the pairs sent, the pairs the DAC played and
// the HDMI frames shown since the sound was enabled. The program fails if
// UNDER or DROPS is not 0.
//
// Built with PLAY=1 DIAG=1 it also watches the video path while the game is
// played, for finding faults that come and go. The A25's cycle counter and
// the pixel clock both come from the 50 MHz oscillator, so every 1650x750
// frame lasts exactly 12,500,000 core cycles; the player timestamps each
// vertical blank it sees while waiting for a frame to be shown and checks
// the period. It counts the non-zero pixels and the bits seen 1 and 0 of
// every frame it hands over and compares them, one frame later, with the
// video unit's PIXELS (nine per NES pixel) and BITS for the frame shown. It
// prints, once a second,
//   TinyNES DIAG S=<s> F=<frames> VBL=<n> PER=<min>..<max> ODD=<n>
//       PIX=<ok>/<bad> LATE=<n> MISS=<n> EMU=<us> AUD=<min>-<max>
//       UND=<n> DROP=<n> LINK=<status>
// with VBL the vertical blanks, PER the extremes of the measured periods in
// core cycles less 12,500,000, ODD the periods more than 5 us off, PIX the
// frames whose PIXELS and BITS matched or did not, LATE and MISS as above,
// EMU the slowest frame, AUD the sound FIFO's level range, UND and DROP its
// underruns and dropped samples, and LINK the UART link's status (all over
// that second), and at once
//   TinyNES DIAG MARK <n> S=<s.ms> F=<frame>     X pressed on a controller
//   TinyNES DIAG START S=<s.ms> F=<frame>        Start pressed
//   TinyNES DIAG PIXBAD F=<frame> PIXELS=<n> WANT=<n> BITS=<x> WANT=<x>
//   TinyNES DIAG PERIOD F=<frame> CYC=<cycles>
// the last two at most three times a second each.

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
// fceu_settings.c: the five APU channel volumes, which FCEUI_Initialize
// leaves at 0.
void nes_bench_apu_volumes(int volume);
// fceu_settings.c: the loaded cartridge's battery-backed save RAM, if it has
// one, as its bytes and how many there are.
uint8_t *nes_bench_battery(uint32_t *len);
// fceu_settings.c: show the loaded game in a palette of 64 RGB triples.
void nes_bench_palette(const uint8_t *rgb);
}
// The presets, generated into the build directory from the core's libretro
// driver: nes_palette_name[] and nes_palette_rgb[] (Makefile).
#include "fceumm_palettes.h"

namespace {
const int SI_GAMEPAD = 1;
const uint8_t JOY_A = 0x01, JOY_B = 0x02, JOY_SELECT = 0x04, JOY_START = 0x08,
	      JOY_UP = 0x10, JOY_DOWN = 0x20, JOY_LEFT = 0x40, JOY_RIGHT = 0x80;
// FCEUmm's libretro driver's defaults, which these runs keep.
const int SOUND_RATE = 48000;
const uint32_t SOUND_VOLUME = 150;
// Each APU channel at full volume, as the libretro driver's defaults.
const int APU_CHANNEL_VOLUME = 256;
// The NES frame period: FCEUmm's NTSC rate of 39375000 / 655171 Hz.
const double NES_FPS = 39375000.0 / 655171.0;
#ifdef NES_PLAY
// The sound FIFO's level at the start of a frame, in sample pairs: nothing
// is corrected within AUDIO_BAND of AUDIO_TARGET. A frame's emulation plays
// up to about 610 pairs before its own are sent and each frame sends about
// 814, so the level stays between about 490 and 1,720 of 2,048.
const uint32_t AUDIO_TARGET = 1100, AUDIO_BAND = 200, AUDIO_PREFILL = 800;
#endif
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
#ifdef NES_PLAY
#ifndef __riscv
#error "PLAY=1 reads the AE350's controllers; there is no PC build of it"
#endif
// 0: until HOME and SELECT are held.
#ifndef NES_FRAMES
#define NES_FRAMES 0
#endif
#ifndef NES_REPORT
#define NES_REPORT 3600
#endif
#endif
#ifndef NES_FRAMES
#define NES_FRAMES 1800
#endif
#ifndef NES_PALETTE
#define NES_PALETTE 0
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

#ifdef NES_PLAY
extern "C" {
#include "load.h"
// tn_wait_tx_idle, to let the save that is printed last reach the pin.
#include "uart.h"
}
// The largest cartridge taken, and the payload's magic, "TNR1".
const size_t CART_MAX = 2u << 20;
const uint32_t CART_MAGIC = 0x31524e54u;
#else
extern "C" const unsigned char nes_rom[], nes_rom_end[];
#endif

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

#ifdef NES_PLAY
// Classic Controller buttons as the pad registers give them: DATA2's low
// half, report bytes 4 and 5, active low (WII-001, tinynes.h).
const uint16_t WII_B = 1u << 14, WII_Y = 1u << 13, WII_LEFT = 1u << 9,
	       WII_UP = 1u << 8,
	       WII_RIGHT = 1u << 7, WII_DOWN = 1u << 6, WII_SELECT = 1u << 4,
	       WII_HOME = 1u << 3, WII_START = 1u << 2;

// The controller buttons this program can tell apart, in the order the host's
// setting file indexes them.  The Classic's word carries sixteen bits and only
// these nine have been identified on this board, so a mapping to anything else
// could not be honoured and is not offered (TinyNES core-log entry 16).
const uint16_t PAD_BIT[] = {
	WII_B, WII_Y, WII_UP, WII_DOWN, WII_LEFT, WII_RIGHT, WII_SELECT, WII_START,
};
const unsigned PAD_BITS = sizeof PAD_BIT / sizeof PAD_BIT[0];

// What the host fills, in one headerless blob: which controller button answers
// to each NES button -- one index into PAD_BIT per NES button, in the order
// JOY_* has them, player 1's eight then player 2's -- and then the picture's
// pixel aspect, then the palette, an index into nes_palette_name[].  These
// bytes are the ABI with the host (TinyTang
// ports/bl616/tang_fpga_uart.c), so the two sides change together, and the
// core asks for sizeof this rather than for a count of its own.  What is here
// is what the program has always done, and what it keeps when the host says
// nothing or answers with fewer bytes than this build asks for.
struct HostSettings {
	uint8_t pad_map[2 * 8];
	uint8_t aspect;
	uint8_t palette;
};
HostSettings host_settings = {
	{
		0, 1, 6, 7, 2, 3, 4, 5,
		0, 1, 6, 7, 2, 3, 4, 5,
	},
	TN_VIDEO_ASPECT_8_7,	// /nes.ini's own default
	NES_PALETTE,		// FCEUmm's own, /nes.ini's default too
};
// The left stick's 6-bit axes centre near 32; this far off centre it
// counts as the D-pad.
const unsigned STICK = 12;

const char *pad_state(unsigned n)
{
	const uint32_t s = TN_PAD_STATUS(n);
	if (!(s & TN_PAD_PRESENT))
		return "absent";
	return s & TN_PAD_CLASSIC ? "classic" : "other";
}

// One controller as an NES pad. The NES's B and A are the Classic's Y and
// B, the lower-left pair, as the user chose; its A and X do nothing.
// Opposite directions together, which an NES pad cannot press, read as
// neither.
uint8_t read_pad(unsigned n, uint16_t &held)
{
	held = 0;
	if ((TN_PAD_STATUS(n) & (TN_PAD_PRESENT | TN_PAD_CLASSIC)) !=
	    (TN_PAD_PRESENT | TN_PAD_CLASSIC))
		return 0;
	const uint32_t lo = TN_PAD_DATA(n);	// captures DATA2 for the next read
	held = (uint16_t)~TN_PAD_DATA2(n);
	const unsigned lx = lo & 63u, ly = lo >> 8 & 63u;

	uint8_t joy = 0;
	const uint8_t *map = host_settings.pad_map + (n != 0 ? 8 : 0);
	for (unsigned i = 0; i < 8; i++) {
		if (map[i] < PAD_BITS && (held & PAD_BIT[map[i]]))
			joy |= (uint8_t)(1u << i);
	}
	// The stick is a convenience, not a remappable button: it steers the
	// D-pad whatever the D-pad itself is mapped to.
	if (held & WII_UP || ly > 32 + STICK)
		joy |= JOY_UP;
	if (held & WII_DOWN || ly < 32 - STICK)
		joy |= JOY_DOWN;
	if (held & WII_LEFT || lx < 32 - STICK)
		joy |= JOY_LEFT;
	if (held & WII_RIGHT || lx > 32 + STICK)
		joy |= JOY_RIGHT;
	if ((joy & (JOY_UP | JOY_DOWN)) == (JOY_UP | JOY_DOWN))
		joy &= (uint8_t)~(JOY_UP | JOY_DOWN);
	if ((joy & (JOY_LEFT | JOY_RIGHT)) == (JOY_LEFT | JOY_RIGHT))
		joy &= (uint8_t)~(JOY_LEFT | JOY_RIGHT);
	return joy;
}

bool quit_held(uint16_t held)
{
	return (held & (WII_HOME | WII_SELECT)) == (WII_HOME | WII_SELECT);
}

// One frame's sound to the DAC's FIFO, steering its level (read at the
// start of the frame) toward AUDIO_TARGET by one sample.
struct AudioStats {
	uint32_t level_min = UINT32_MAX, level_max = 0;
	unsigned repeated = 0, dropped = 0;
	uint32_t pushed = 0;
};

void send_audio(const int32_t *sound, int32_t count, uint32_t level,
		AudioStats &stats)
{
	if (level < stats.level_min)
		stats.level_min = level;
	if (level > stats.level_max)
		stats.level_max = level;
	if (count <= 0)
		return;
	int32_t n = count;
	if (level > AUDIO_TARGET + AUDIO_BAND && n > 1) {
		n--;
		stats.dropped++;
	}
	// Each element is a 16-bit mono sample, as FCEUmm's libretro driver
	// takes it: the same in both halves.
	for (int32_t i = 0; i < n; i++)
		TN_AUDIO_DATA = (uint32_t)sound[i] << 16 | ((uint32_t)sound[i] & 0xffffu);
	stats.pushed += (uint32_t)n;
	if (level < AUDIO_TARGET - AUDIO_BAND) {
		TN_AUDIO_DATA = (uint32_t)sound[n - 1] << 16 |
				((uint32_t)sound[n - 1] & 0xffffu);
		stats.repeated++;
		stats.pushed++;
	}
}
#endif

#ifdef NES_DIAG
const uint64_t FRAME_CYCLES = 12500000u;     // 750 MHz / 60 Hz
const uint64_t PERIOD_SLACK = 3750u;         // 5 us, the EXTS polling
const uint16_t WII_X = 1u << 11;
const unsigned EVENTS_PER_SECOND = 3;

// A frame's non-zero pixels and the bits seen 1 (low byte) and 0 (high byte),
// as the video unit's PIXELS / 9 and BITS give them.
struct FrameSum {
	uint32_t nonzero;
	uint16_t bits;
};

FrameSum frame_sum(const uint8_t *fb)
{
	const uint32_t *w = reinterpret_cast<const uint32_t *>(fb);
	uint32_t total = 0, lanes = 0, ones = 0, zeros = 0;
	unsigned run = 0;
	for (unsigned i = 0; i < WIDTH * HEIGHT / 4; i++) {
		const uint32_t v = w[i];
		ones |= v;
		zeros |= ~v;
		// Bit 7 of each byte lane set where that byte is not zero.
		lanes += ((((v & 0x7f7f7f7fu) + 0x7f7f7f7fu) | v) & 0x80808080u) >> 7;
		if (++run == 255 || i + 1 == WIDTH * HEIGHT / 4) {
			total += (lanes & 0xff) + (lanes >> 8 & 0xff) +
				 (lanes >> 16 & 0xff) + (lanes >> 24);
			lanes = 0;
			run = 0;
		}
	}
	ones |= ones >> 16;
	ones |= ones >> 8;
	zeros |= zeros >> 16;
	zeros |= zeros >> 8;
	return {total, (uint16_t)((zeros & 0xff) << 8 | (ones & 0xff))};
}

struct Diag {
	FrameSum expect[2] = {};
	bool expect_valid[2] = {};
	// The last vertical blank seen while waiting, if the one before it was
	// too, and the buffer shown from it.
	bool live = false;
	uint32_t edge_frames = 0;
	uint64_t edge_t = 0;
	unsigned shown = 0;
	// This second.
	uint64_t second_t = 0;
	unsigned seconds = 0, frames = 0, odd = 0, pix_ok = 0, pix_bad = 0;
	unsigned missed = 0, events_pix = 0, events_period = 0;
	int64_t per_min = INT64_MAX, per_max = INT64_MIN;
	uint64_t emu_max = 0;
	uint32_t level_min = UINT32_MAX, level_max = 0;
	uint32_t vbl0 = 0, late0 = 0, under0 = 0, drops0 = 0, link = 0;
	unsigned marks = 0;
	uint16_t held_prev = 0;
	uint64_t start_t = 0;
};

void diag_stamp(const Diag &d, uint64_t t, unsigned frame, const char *what)
{
	const uint64_t ms = to_us(t - d.start_t) / 1000u;
	printf("TinyNES DIAG %s S=%llu.%03llu F=%u\n", what,
	       (unsigned long long)(ms / 1000u), (unsigned long long)(ms % 1000u), frame);
}

// A vertical blank seen at t, FRAMES then f: check the period since the last
// and the frame the video unit has just finished showing.
void diag_edge(Diag &d, uint32_t f, uint64_t t, unsigned frame)
{
	if (d.live && f - d.edge_frames == 1) {
		const int64_t dev = (int64_t)(t - d.edge_t) - (int64_t)FRAME_CYCLES;
		if (dev < d.per_min)
			d.per_min = dev;
		if (dev > d.per_max)
			d.per_max = dev;
		if (dev > (int64_t)PERIOD_SLACK || dev < -(int64_t)PERIOD_SLACK) {
			d.odd++;
			if (d.events_period++ < EVENTS_PER_SECOND)
				printf("TinyNES DIAG PERIOD F=%u CYC=%llu\n", frame,
				       (unsigned long long)(t - d.edge_t));
		}
		if (d.expect_valid[d.shown]) {
			const FrameSum &e = d.expect[d.shown];
			const uint32_t pixels = TN_VIDEO_PIXELS, bits = TN_VIDEO_BITS & 0xffffu;
			if (pixels == 9u * e.nonzero && bits == e.bits) {
				d.pix_ok++;
			} else {
				d.pix_bad++;
				if (d.events_pix++ < EVENTS_PER_SECOND)
					printf("TinyNES DIAG PIXBAD F=%u PIXELS=%lu WANT=%lu "
					       "BITS=%04lx WANT=%04x\n", frame,
					       (unsigned long)pixels,
					       (unsigned long)(9u * e.nonzero),
					       (unsigned long)bits, e.bits);
			}
		}
	}
	d.live = true;
	d.edge_frames = f;
	d.edge_t = t;
	d.shown = TN_VIDEO_STATUS & TN_VIDEO_BUFFER ? 1 : 0;
}

// Wait, as the plain player does, until the buffer asked for is shown, but
// timestamp each vertical blank on the way. A frame that was already shown
// on arrival (the emulation ran over) breaks the run of seen blanks.
void diag_wait(Diag &d, uint32_t want, unsigned frame)
{
	const uint32_t mask = TN_VIDEO_SHOWING | TN_VIDEO_BUFFER;
	if ((TN_VIDEO_STATUS & mask) == want) {
		d.live = false;
		return;
	}
	uint32_t f0 = TN_VIDEO_FRAMES;
	for (;;) {
		const uint32_t f = TN_VIDEO_FRAMES;
		if (f == f0)
			continue;
		diag_edge(d, f, ticks(), frame);
		f0 = f;
		// STATUS and FRAMES cross from the pixel clock separately.
		for (int i = 0; i < 64; i++)
			if ((TN_VIDEO_STATUS & mask) == want)
				return;
	}
}

void diag_second(Diag &d, uint64_t t)
{
	const uint32_t vbl = TN_VIDEO_FRAMES, late = TN_VIDEO_LATE;
	const uint32_t status = TN_AUDIO_STATUS, drops = TN_AUDIO_DROPS;
	printf("TinyNES DIAG S=%u F=%u VBL=%lu PER=%lld..%lld ODD=%u PIX=%u/%u LATE=%lu "
	       "MISS=%u EMU=%llu AUD=%lu-%lu UND=%lu DROP=%lu LINK=%08lx\n",
	       d.seconds, d.frames, (unsigned long)(vbl - d.vbl0),
	       (long long)(d.per_min == INT64_MAX ? 0 : d.per_min),
	       (long long)(d.per_max == INT64_MIN ? 0 : d.per_max), d.odd, d.pix_ok,
	       d.pix_bad, (unsigned long)(late - d.late0), d.missed,
	       (unsigned long long)to_us(d.emu_max),
	       (unsigned long)(d.level_min == UINT32_MAX ? 0 : d.level_min),
	       (unsigned long)d.level_max,
	       (unsigned long)(TN_AUDIO_UNDERRUNS(status) - d.under0),
	       (unsigned long)(drops - d.drops0), (unsigned long)TN_LINK_STATUS);
	d.seconds++;
	d.second_t = t;
	d.frames = d.odd = d.pix_ok = d.pix_bad = d.missed = 0;
	d.events_pix = d.events_period = 0;
	d.per_min = INT64_MAX;
	d.per_max = INT64_MIN;
	d.emu_max = 0;
	d.level_min = UINT32_MAX;
	d.level_max = 0;
	d.vbl0 = vbl;
	d.late0 = late;
	d.under0 = TN_AUDIO_UNDERRUNS(status);
	d.drops0 = drops;
}
#endif

#ifndef NES_PLAY
uint8_t pad_for(unsigned frame)
{
	uint8_t mask = 0;
	for (unsigned i = 0; i < press_count; i++)
		if (frame >= presses[i].first &&
		    frame - presses[i].first < presses[i].count)
			mask |= presses[i].buttons;
	return mask;
}
#endif

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

#ifdef NES_PLAY
// Ask for the cartridge and receive it into the heap; its bytes and length,
// or nullptr if none came within 30 seconds or it was malformed.
const uint8_t *receive_cart(size_t &size)
{
	uint8_t *buffer = static_cast<uint8_t *>(malloc(CART_MAX + 8));
	if (!buffer)
		return nullptr;
	printf("TinyNES WANT %08lx %08lx\n", (unsigned long)(uintptr_t)buffer,
	       (unsigned long)(CART_MAX + 8));
	fflush(stdout);
	tn_load_reset();
	uint32_t got = 0;
	for (int second = 0; second < 30 && !got; second++)
		got = tn_load_poll(TN_CORE_HZ);
	uint32_t magic, length;
	memcpy(&magic, buffer, 4);
	memcpy(&length, buffer + 4, 4);
	if (got != (uintptr_t)buffer || magic != CART_MAGIC || length == 0 ||
	    length > CART_MAX)
		return nullptr;
	size = length;
	return buffer + 8;
}

// A battery-backed cartridge's save RAM, as the core has it once the
// cartridge is loaded: where its bytes are and how many there are.
uint8_t *save_ram;
uint32_t save_len;

// The link frames this program's bytes and the board keeps only a handful of
// frames in hand, draining its receive ring a frame at a time; a burst of
// lines overruns that and frames are dropped. So each line waits for the link
// to be idle and then leaves the board 4 ms to file it. That costs about a
// second on an 8 KiB save and keeps every byte.
void save_pace()
{
	tn_wait_tx_idle();
	const uint64_t until = ticks() + tick_hz / 250;
	while (ticks() < until)
		;
}

// A battery the game never wrote is whatever the core allocated for it: every
// byte the same. Worth saying out loud, because from the card a blank save and
// a real one look identical, and "it saved" at one end with a silent game at
// the other cannot tell the two apart.
bool save_is_blank()
{
	for (uint32_t i = 1; i < save_len; i++) {
		if (save_ram[i] != save_ram[0])
			return false;
	}
	return true;
}

// Ask the host which controller button answers to each NES button, and for the
// picture's aspect and palette, and take the answer into host_settings.  Headerless,
// exactly as a save is, and for the same reason: it lands directly in the
// buffer.  The host always has an answer -- its defaults at worst -- so this
// does not wait the way a save that may not exist does, and nothing arriving
// leaves what was compiled in.
void receive_settings()
{
	printf("TinyNES SETTINGS WANT %08lx %08lx\n",
	       (unsigned long)(uintptr_t)&host_settings,
	       (unsigned long)sizeof host_settings);
	fflush(stdout);
	tn_load_reset();
	uint32_t got = 0;
	for (int step = 0; step < 10 && !got; step++)
		got = tn_load_poll(TN_CORE_HZ / 10);
}

// Ask the host for a saved battery file and take it into the core's own
// buffer, so the game starts where it was left. The host sends it in the
// boot ROM's load protocol, as it sends the cartridge. The save RAM the
// core has after loading is blank, and stays that way when nothing arrives
// within about a second, which is the usual case and not an error.
void receive_save()
{
	if (!save_ram || !save_len)
		return;
	printf("TinyNES NVRAM WANT %08lx %08lx\n", (unsigned long)(uintptr_t)save_ram,
	       (unsigned long)save_len);
	fflush(stdout);
	tn_load_reset();
	uint32_t got = 0;
	for (int step = 0; step < 10 && !got; step++)
		got = tn_load_poll(TN_CORE_HZ / 10);
	// The load's own checksums judge the payload, and its entry, which the
	// file protocol puts at the address the image was framed for, says that
	// address was this buffer: anything else leaves the blank save RAM alone.
	if (got != (uintptr_t)save_ram)
		return;
	// What actually landed, and its CRC: the same number the save printed when
	// it was written means the round trip is byte-perfect and the game not
	// seeing it is the game's side of the problem, not the link's.
	printf("TinyNES NVRAM GOT %lu %08lx%s\n", (unsigned long)save_len,
	       (unsigned long)crc_update(0, save_ram, save_len),
	       save_is_blank() ? " BLANK" : "");
	// The first and last few bytes as they now stand.  A save the game will
	// accept has structure in it; the round trip being byte-perfect and the
	// game still showing an empty slot means the question is what these are.
	printf("TinyNES NVRAM HEAD");
	for (uint32_t i = 0; i < 24 && i < save_len; i++)
		printf(" %02x", save_ram[i]);
	printf("\nTinyNES NVRAM TAIL");
	for (uint32_t i = save_len > 24 ? save_len - 24 : 0; i < save_len; i++)
		printf(" %02x", save_ram[i]);
	printf("\n");
	fflush(stdout);
}
#endif

// Show the game in palette n, an index into nes_palette_name[]: 0 is the
// palette the core chose when it loaded the game, which is left as it is,
// and an index this build does not know is taken as 0.  Returns the index
// shown, for the report.
unsigned set_palette(unsigned n)
{
	if (n == 0 || n >= NES_PALETTE_COUNT)
		return 0;
	nes_bench_palette(nes_palette_rgb[n - 1]);
	return n;
}

int main()
{
#ifdef NES_PLAY
	size_t rom_size = 0;
	const uint8_t *const nes_rom = receive_cart(rom_size);
	if (!nes_rom) {
		printf("TinyNES NES BAD CART\n");
		return 1;
	}
#else
	const size_t rom_size = (size_t)(nes_rom_end - nes_rom);
#endif
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
	nes_bench_apu_volumes(APU_CHANNEL_VOLUME);
	FCEUI_SetSoundVolume(SOUND_VOLUME);
#ifdef NES_PLAY
	const int sound_rate = (int)((double)TN_AUDIO_RATE_NUM / TN_AUDIO_RATE_DEN *
				     NES_FPS / 60.0 + 0.5);
	FCEUI_Sound(sound_rate);
#else
	FCEUI_Sound(SOUND_RATE);
#endif
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
#ifndef NES_PLAY
	printf("TinyNES NES PALETTE=%s\n", nes_palette_name[set_palette(NES_PALETTE)]);
#endif
#ifdef NES_PLAY
	// A battery-backed cartridge's save RAM: ask for a saved one and take it
	// into the core's own buffer, before the first frame runs.
	save_ram = nes_bench_battery(&save_len);
	receive_save();
	receive_settings();
	// The picture's pixel aspect, from /nes.ini through the host.  Written
	// here because the register is taken at the next vertical blank and this
	// is well before the first frame; a host that sent fewer bytes than this
	// build asked for leaves the compiled-in default in place.
	TN_VIDEO_ASPECT = host_settings.aspect <= TN_VIDEO_ASPECT_4_3
				  ? host_settings.aspect
				  : TN_VIDEO_ASPECT_8_7;
	// The palette, from the same answer.  The core writes it to the video
	// unit's palette store as it goes, before the first frame is shown.
	printf("TinyNES NES PALETTE=%s\n",
	       nes_palette_name[set_palette(host_settings.palette)]);
	// Link mode last: the host answers the save request as a line, which it
	// can only do while the link is still the boot ROM's, and from here on
	// this program's bytes go out as TinyDesk text frames instead.
	printf("TinyNES LINK\n");
	fflush(stdout);
	TN_UART_CTRL = TN_UART_LINK_MODE;
#endif
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
#ifdef NES_PLAY
	if (TN_PAD_ID != TN_PAD_ID_VALUE) {
		printf("TinyNES NES BAD PAD ID=%08lx\n", (unsigned long)TN_PAD_ID);
		return 1;
	}
	if (TN_AUDIO_ID != TN_AUDIO_ID_VALUE) {
		printf("TinyNES NES BAD AUDIO ID=%08lx\n", (unsigned long)TN_AUDIO_ID);
		return 1;
	}
	printf("TinyNES NES PLAY PAD1=%s PAD2=%s SOUND=%d\n", pad_state(0),
	       pad_state(1), sound_rate);
	TN_AUDIO_CTRL = TN_AUDIO_FLUSH;
	for (uint32_t i = 0; i < AUDIO_PREFILL; i++)
		TN_AUDIO_DATA = 0;
	const uint32_t under0 = TN_AUDIO_UNDERRUNS(TN_AUDIO_STATUS);
	const uint32_t drops0 = TN_AUDIO_DROPS;
	AudioStats audio;
	uint64_t push_total = 0;
	uint32_t played0 = 0, vbl0 = 0;
#ifdef NES_DIAG
	Diag diag;
	diag.start_t = diag.second_t = ticks();
	diag.vbl0 = TN_VIDEO_FRAMES;
	diag.late0 = TN_VIDEO_LATE;
	diag.under0 = TN_AUDIO_UNDERRUNS(TN_AUDIO_STATUS);
	diag.drops0 = TN_AUDIO_DROPS;
	printf("TinyNES DIAG ON FRAME=%llu SLACK=%llu\n",
	       (unsigned long long)FRAME_CYCLES, (unsigned long long)PERIOD_SLACK);
#endif
#endif
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
	unsigned over = 0, part_frames = 0, back = 1, played = 0;

	for (unsigned f = 0; frames == 0 || f < frames; f++) {
#ifdef NES_PLAY
		uint16_t held1, held2;
		joypads = read_pad(0, held1) | (uint32_t)read_pad(1, held2) << 8;
		if (quit_held(held1) || quit_held(held2))
			break;
		// The desktop is over the game: its pointer has the controller.
		if (TN_LINK_STATUS & TN_LINK_SHOWN)
			joypads = 0;
#ifdef NES_DIAG
		{
			const uint16_t held = held1 | held2;
			const uint16_t pressed = held & (uint16_t)~diag.held_prev;
			diag.held_prev = held;
			if (pressed & WII_X) {
				char what[16];
				snprintf(what, sizeof what, "MARK %u", ++diag.marks);
				diag_stamp(diag, ticks(), f, what);
			}
			if (pressed & WII_START)
				diag_stamp(diag, ticks(), f, "START");
		}
#endif
		const uint32_t audio_level = TN_AUDIO_LEVEL(TN_AUDIO_STATUS);
#else
		joypads = pad_for(f);
#endif
		XBuf = frame_buffer(back);

		uint8_t *pixels;
		int32_t *sound;
		int32_t sound_size = 0;
		uint64_t t = ticks();
		FCEUI_Emulate(&pixels, &sound, &sound_size, 0);
		t = ticks() - t;
#ifdef NES_PLAY
		const uint64_t a = ticks();
		send_audio(sound, sound_size, audio_level, audio);
		if (f == 0) {
			TN_AUDIO_CTRL = TN_AUDIO_ENABLE;
			played0 = TN_AUDIO_FRAMES;
			vbl0 = TN_VIDEO_FRAMES;
		}
		push_total += ticks() - a;
#endif

#ifdef NES_DIAG
		diag.expect[back] = frame_sum(frame_buffer(back));
		diag.expect_valid[back] = true;
		if (t > diag.emu_max)
			diag.emu_max = t;
		if (audio_level < diag.level_min)
			diag.level_min = audio_level;
		if (audio_level > diag.level_max)
			diag.level_max = audio_level;
#endif
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
#ifdef NES_DIAG
		diag_wait(diag, want, f);
#else
		while ((TN_VIDEO_STATUS & (TN_VIDEO_SHOWING | TN_VIDEO_BUFFER)) != want)
			;
#endif
		if (TN_VIDEO_FRAMES - vbl > 1) {
			missed++;
#ifdef NES_DIAG
			diag.missed++;
#endif
		}
#ifdef NES_DIAG
		diag.frames++;
		{
			const uint64_t now = ticks();
			if (now - diag.second_t >= tick_hz)
				diag_second(diag, now);
		}
#endif
#else
		s = 0;
#endif
		back ^= 1;
		played = f + 1;

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
#ifdef NES_PLAY
	const uint32_t under = TN_AUDIO_UNDERRUNS(TN_AUDIO_STATUS) - under0;
	const uint32_t drops = TN_AUDIO_DROPS - drops0;
	const uint32_t played_pairs = TN_AUDIO_FRAMES - played0;
	const uint32_t vbl_count = TN_VIDEO_FRAMES - vbl0;
	TN_AUDIO_CTRL = TN_AUDIO_FLUSH;
#else
	const uint32_t under = 0, drops = 0;
#endif
#else
	const unsigned late = 0, missed = 0;
	const uint32_t under = 0, drops = 0;
#endif
	const unsigned n = played ? played : 1;
	const uint64_t avg = total / n ? total / n : 1;
	if (!played)
		low = 0;
	const unsigned speed = (unsigned)(budget * 1000u / avg);
	printf("TinyNES NES FRAMES=%u AVG=%llu MIN=%llu MAX=%llu SHOW=%llu "
	       "OVER=%u SPEED=%u.%u%% LATE=%u MISSED=%u\n", played,
	       (unsigned long long)to_us(avg), (unsigned long long)to_us(low),
	       (unsigned long long)to_us(high),
	       (unsigned long long)to_us(show_total / n), over, speed / 10,
	       speed % 10, late, missed);
	printf("TinyNES NES VIDEO=%08lx AUDIO=%08lx\n", (unsigned long)video_crc,
	       (unsigned long)audio_crc);
#ifdef NES_PLAY
	printf("TinyNES NES AUDIO UNDER=%lu DROPS=%lu LEVEL=%lu-%lu ADJUST=+%u/-%u "
	       "PUSH=%llu PUSHED=%lu PLAYED=%lu VBL=%lu\n", (unsigned long)under,
	       (unsigned long)drops, (unsigned long)(played ? audio.level_min : 0),
	       (unsigned long)audio.level_max, audio.repeated, audio.dropped,
	       (unsigned long long)to_us(push_total / n),
	       (unsigned long)audio.pushed, (unsigned long)played_pairs,
	       (unsigned long)vbl_count);

	// A battery-backed cartridge's save RAM goes back to the host as text:
	// link mode drops carriage returns and splits lines, so binary cannot go
	// as it is, and four bits to a hex digit leave neither. The core wrote
	// it through the D-cache, so that is written back before it is read.
	if (save_ram && save_len) {
		tn_dcache_wbinval();
		const uint32_t save_crc = crc_update(0, save_ram, save_len);
		// The header used to be the first thing to cross the link after the
		// summary, and a burst's opening is where the link loses a chunk:
		// on 2026-10-14 the header arrived as "TinyNES N" and the save was
		// never armed, so the header is not sent until the link is warm.
		for (int lead = 0; lead < 3; lead++) {
			printf("TinyNES NVRAM BEGIN\n");
			save_pace();
		}
		// A save the game never wrote is still what the core allocated: every
		// byte the same.  Say so, or a blank file looks like a working save
		// and the next launch looks like a broken one.
		const bool blank = save_is_blank();
		printf("TinyNES NVRAM SAVE %lu %08lx%s\n", (unsigned long)save_len,
		       (unsigned long)save_crc, blank ? " BLANK" : "");
		save_pace();
		const char *const digits = "0123456789abcdef";
		char hex[65];
		unsigned n = 0;
		for (uint32_t i = 0; i < save_len; i++) {
			hex[n++] = digits[save_ram[i] >> 4];
			hex[n++] = digits[save_ram[i] & 15];
			// 32 bytes to a line, 64 hex digits, and a line ends only
			// where the link's framing expects one, at a newline.
			if (n == 64) {
				hex[n] = 0;
				printf("%s\n", hex);
				save_pace();
				n = 0;
			}
		}
		if (n) {
			hex[n] = 0;
			printf("%s\n", hex);
			save_pace();
		}
		printf("TinyNES NVRAM DONE %08lx\n", (unsigned long)save_crc);
		tn_wait_tx_idle();
		save_pace();
	}
#endif

	// The last frame stays on screen; the core frees only its own buffer.
	XBuf = core_xbuf;
	FCEUI_CloseGame();
	FCEUI_Kill();
#if defined(__riscv) && defined(NES_MCACHE)
	__asm__ volatile("csrc 0x7ca, %0" : : "r"((uint32_t)NES_MCACHE));
#endif
	return late || under || drops ? 1 : 0;
}
