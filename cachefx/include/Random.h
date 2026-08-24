#ifndef __RANDOM_H__
#define __RANDOM_H__ 1

#include <cstdint>

#if defined(__aarch64__)
#include <sys/auxv.h>
#include <asm/hwcap.h>
#include <random>
#endif

class Random {
private:
  static Random *instance;
  uint64_t state;

  Random(uint64_t seed) : state(seed) {};

  Random() : Random(rdrand()) {
    for (int32_t i = 0; i < 100; i++)
      rand();
  };

public:
  static Random *get(void) { return instance; };

  uint64_t rand() {
    uint64_t x = state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state = x;
    return x;
  };

  void seed(uint64_t seed) { state = seed; };

  static uint64_t rdrand() {
#if defined(__aarch64__)

    // Check whether Linux actually exposes FEAT_RNG to this process.
    if (getauxval(AT_HWCAP2) & HWCAP2_RNG) {
      uint64_t r;

      asm volatile(
          ".arch_extension rng\n\t"
          "mrs %0, RNDR"
          : "=r"(r));

      return r;
    }

    // ARM64 machine/VM does not expose RNDR.
    std::random_device rd;
    uint64_t r =
        (static_cast<uint64_t>(rd()) << 32) |
        static_cast<uint64_t>(rd());

    return r ? r : 1;

#elif defined(__x86_64__) || defined(__i386__)

    uint64_t r;
    asm volatile("rdrand %0" : "=r"(r));
    return r;

#else
#error Unsupported architecture
#endif
  };
};

static inline bool randomBool() { return Random::get()->rand() & 0x01; }
static inline uint8_t randomUint8() { return Random::get()->rand() & 0xff; }

#endif //__RANDOM_H__
