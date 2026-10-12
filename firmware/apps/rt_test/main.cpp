// SPDX-License-Identifier: MIT
//
// TinyNES AE350 runtime self-test. Checks that the C++ runtime works
// (static constructors, the containers, exceptions, RTTI, heap) and newlib's
// formatted output and maths, then tests and measures the SDRAM left for the
// heap with the caches on, and reports:
//
//   TinyNES RT OK MISA=<misa> HEAP=<KiB>K
//   TinyNES SDRAM OK <KiB>K MISS=<cycles> RD=<KB/s> WR=<KB/s> FULL=<ms>
//
// MISA is the A25's misa CSR (hex). HEAP is the largest block malloc gives,
// which the SDRAM line tests. MISS is the core cycles per cache line read
// one word per line, RD and WR the rates reading and writing 1 MiB word by
// word, and FULL the time the cached pattern test took. A failed check
// prints BAD RT <name> and the program exits with 1.
#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <typeinfo>
#include <vector>

#include "memtest.h"
#include "tinynes.h"

namespace {

int failures;

void check(bool ok, const char *name)
{
	if (!ok) {
		failures++;
		std::printf("BAD RT %s\n", name);
	}
}

int constructed;
struct Constructor {
	Constructor() { constructed = 0x1234; }
} constructor;

struct Base {
	virtual ~Base() = default;
	virtual int value() const { return 1; }
};

struct Derived : Base {
	int value() const override { return 2; }
};

struct Other : Base {};

volatile int throw_selector = 1;

[[gnu::noinline]] int may_throw(int kind)
{
	if (kind == 1)
		throw std::runtime_error("runtime");
	if (kind == 2)
		throw 42;
	return kind;
}

void test_cpp()
{
	check(constructed == 0x1234, "CTOR");

	std::vector<int> numbers;
	for (int i = 0; i < 1000; i++)
		numbers.push_back(i);
	long sum = 0;
	for (int n : numbers)
		sum += n;
	check(sum == 499500, "VECTOR");

	std::string text = "Tiny";
	text += "NES";
	text += std::to_string(138);
	check(text == "TinyNES138", "STRING");

	std::map<std::string, int> map;
	map["b"] = 2;
	map["a"] = 1;
	map["c"] = 3;
	check(map.begin()->first == "a" && map.size() == 3, "MAP");

	std::unique_ptr<Base> object = std::make_unique<Derived>();
	check(object->value() == 2, "VIRTUAL");
	check(dynamic_cast<Derived *>(object.get()) != nullptr &&
	      dynamic_cast<Other *>(object.get()) == nullptr, "DYNAMIC_CAST");
	check(typeid(*object) == typeid(Derived), "TYPEID");

	bool caught = false;
	try {
		may_throw(throw_selector);
	} catch (const std::exception &e) {
		caught = std::strcmp(e.what(), "runtime") == 0;
	}
	check(caught, "THROW");

	caught = false;
	try {
		may_throw(throw_selector + 1);
	} catch (int value) {
		caught = value == 42;
	}
	check(caught, "THROW_INT");
}

void test_libc()
{
	volatile double pi = 3.14159265358979;
	volatile double two = 2.0;
	char buffer[32];

	std::snprintf(buffer, sizeof buffer, "%.3f %" PRIx32, pi, UINT32_C(0xbeef));
	check(std::strcmp(buffer, "3.142 beef") == 0, "SNPRINTF");
	double root = std::sqrt(two);
	check(std::fabs(root * root - 2.0) < 1e-12, "SQRT");
}

uint32_t kbps(uint32_t bytes, uint32_t cycles)
{
	return static_cast<uint32_t>(uint64_t{bytes / 1024} * TN_CORE_HZ / cycles);
}

struct Speed {
	uint32_t miss_cycles;
	uint32_t read_kbps;
	uint32_t write_kbps;
};

constexpr uint32_t measure_bytes = 1u << 20;

Speed measure(volatile uint32_t *base)
{
	volatile uint32_t *end = base + measure_bytes / 4;
	uint32_t total = 0, start, cycles;
	Speed speed;

	tn_dcache_wbinval();
	start = tn_cycles();
	for (volatile uint32_t *p = base; p < end; p += 8)
		total += *p;
	cycles = tn_cycles() - start;
	speed.miss_cycles = cycles / (measure_bytes / 32);

	tn_dcache_wbinval();
	start = tn_cycles();
	for (volatile uint32_t *p = base; p < end; p++)
		total += *p;
	cycles = tn_cycles() - start;
	speed.read_kbps = kbps(measure_bytes, cycles);

	tn_dcache_wbinval();
	start = tn_cycles();
	for (volatile uint32_t *p = base; p < end; p++)
		*p = total;
	tn_dcache_wbinval();
	cycles = tn_cycles() - start;
	speed.write_kbps = kbps(measure_bytes, cycles);
	return speed;
}

} // namespace

int main()
{
	uint32_t misa;
	__asm__ volatile("csrr %0, misa" : "=r"(misa));

	test_cpp();
	test_libc();

	constexpr size_t step = 64u << 10;
	size_t heap = TN_SDRAM_BYTES;
	void *block = nullptr;
	while (heap > step && !(block = std::malloc(heap)))
		heap -= step;
	check(block && heap >= (16u << 20), "MALLOC");
	if (failures)
		return 1;
	std::printf("TinyNES RT OK MISA=%08" PRIx32 " HEAP=%" PRIu32 "K\n", misa,
		    static_cast<uint32_t>(heap >> 10));

	auto *start = static_cast<volatile uint32_t *>(block);
	auto *end = start + heap / 4;
	tn_result full{};
	Speed speed = measure(start);
	uint64_t full_start = tn_cycles64();
	tn_test_words(&full, 0x13579bdfu, 1, start, end);
	auto full_ms = static_cast<uint32_t>((tn_cycles64() - full_start) /
					     (TN_CORE_HZ / 1000));
	std::free(block);
	if (full.failures) {
		std::printf("BAD RT SDRAM N=%08" PRIx32 " A=%08" PRIx32 " E=%08" PRIx32
			    " G=%08" PRIx32 "\n", full.failures, full.addr,
			    full.expected, full.got);
		return 1;
	}
	std::printf("TinyNES SDRAM OK %" PRIu32 "K MISS=%" PRIu32 " RD=%" PRIu32
		    " WR=%" PRIu32 " FULL=%" PRIu32 "\n",
		    static_cast<uint32_t>(heap >> 10), speed.miss_cycles,
		    speed.read_kbps, speed.write_kbps, full_ms);
	return 0;
}
