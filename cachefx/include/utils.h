#ifndef __UTILS_H__
#define __UTILS_H__

#include <cassert>

constexpr uint64_t mask(unsigned nbits) {
  return (nbits >= 64) ? (uint64_t)-1LL : (1ULL << nbits) - 1;
}

template <class T> constexpr T mbits(T val, unsigned first, unsigned last) {
  return val & (mask(first + 1) & ~mask(last));
}

constexpr uint64_t mask(unsigned first, unsigned last) {
  return mbits((uint64_t)-1LL, first, last);
}

template <class T> constexpr T bits(T val, unsigned first, unsigned last) {
  assert(first >= last);
  int nbits = first - last + 1;
  return (val >> last) & mask(nbits);
}

template <class T> constexpr T bits(T val, unsigned bit) {
  return bits(val, bit, bit);
}

template <class T>
static constexpr std::enable_if_t<std::is_integral<T>::value, int>
floorLog2(T x) {
  assert(x > 0);

  // A guaranteed unsigned version of x.
  uint64_t ux = (typename std::make_unsigned<T>::type)x;

  int y = 0;
  constexpr auto ts = sizeof(T);

  if (ts >= 8 && (ux & 0xffffffff00000000ULL)) {
    y += 32;
    ux >>= 32;
  }
  if (ts >= 4 && (ux & 0x00000000ffff0000ULL)) {
    y += 16;
    ux >>= 16;
  }
  if (ts >= 2 && (ux & 0x000000000000ff00ULL)) {
    y += 8;
    ux >>= 8;
  }
  if (ux & 0x00000000000000f0ULL) {
    y += 4;
    ux >>= 4;
  }
  if (ux & 0x000000000000000cULL) {
    y += 2;
    ux >>= 2;
  }
  if (ux & 0x0000000000000002ULL) {
    y += 1;
  }

  return y;
}

template <class T, class B>
constexpr T insertBits(T val, unsigned first, unsigned last, B bit_val) {
  assert(first >= last);
  T bmask = mask(first, last);
  val &= ~bmask;
  val |= ((T)bit_val << last) & bmask;
  return val;
}

template <class T, class B>
constexpr T insertBits(T val, unsigned bit, B bit_val) {
  return insertBits(val, bit, bit, bit_val);
}

#endif /* __UTILS_H__ */