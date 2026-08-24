#include <Cache/SkewedAssocCache.h>
#include <cmath>
#include <crypto/speck.h>
#include <iostream>
#include <utils.h>

const char *SkewedAssocCache::CACHE_TYPESTR = "skewed-assoc";

SkewedAssocCache::SkewedAssocCache(size_t sets, size_t ways)
    : SkewedAssocCache(REPL_RANDOM, sets, ways) {}

SkewedAssocCache::SkewedAssocCache(replAlg algorithm, size_t sets, size_t ways)
    : _nSets(sets), _nWays(ways), _invalidFirst(false), _algorithm(algorithm),
      _clock(0), msbShift(floorLog2(_nSets) - 1), _num_skewing_functions(8),
      setShift(6), setMask(sets - 1) {
  _cacheEntries.resize(_nWays);
  for (size_t w = 0; w < _nWays; w++) {
    _cacheEntries[w].resize(_nSets);
    for (size_t s = 0; s < _nSets; s++) {
      _cacheEntries[w][s].tag = TAG_INIT;
      _cacheEntries[w][s].accessTime = _clock++;
      _cacheEntries[w][s].flags = 0;
    }
  }
}

SkewedAssocCache::~SkewedAssocCache() {}

tag_t SkewedAssocCache::hash(const tag_t addr) const {
  // Get relevant bits
  const uint8_t lsb = bits<tag_t>(addr, 0);
  const uint8_t msb = bits<tag_t>(addr, msbShift);
  const uint8_t xor_bit = msb ^ lsb;

  // Shift-off LSB and set new MSB as xor of old LSB and MSB
  return insertBits<tag_t, uint8_t>(addr >> 1, msbShift, xor_bit);
}

tag_t SkewedAssocCache::dehash(const tag_t addr) const {
  const uint8_t msb = bits<tag_t>(addr, msbShift - 1);
  const uint8_t xor_bit = bits<tag_t>(addr, msbShift);
  const uint8_t lsb = msb ^ xor_bit;

  const tag_t addr_no_msb = mbits<tag_t>(addr, msbShift - 1, 0);
  return insertBits<tag_t, tag_t>(addr_no_msb << 1, 0, lsb);
}

tag_t SkewedAssocCache::skew(const tag_t addr, const size_t way) const {
  tag_t addr1 = bits<tag_t>(addr, msbShift, 0);
  const tag_t addr2 = bits<tag_t>(addr, 2 * (msbShift + 1) - 1, msbShift + 1);

  // Select and apply skewing function for given way
  switch (way % _num_skewing_functions) {
  case 0:
    addr1 = hash(addr1) ^ hash(addr2) ^ addr2;
    break;
  case 1:
    addr1 = hash(addr1) ^ hash(addr2) ^ addr1;
    break;
  case 2:
    addr1 = hash(addr1) ^ dehash(addr2) ^ addr2;
    break;
  case 3:
    addr1 = hash(addr1) ^ dehash(addr2) ^ addr1;
    break;
  case 4:
    addr1 = dehash(addr1) ^ hash(addr2) ^ addr2;
    break;
  case 5:
    addr1 = dehash(addr1) ^ hash(addr2) ^ addr1;
    break;
  case 6:
    addr1 = dehash(addr1) ^ dehash(addr2) ^ addr2;
    break;
  case 7:
    addr1 = dehash(addr1) ^ dehash(addr2) ^ addr1;
    break;
    // default:
    // fprintf(stderr, "Warning: suboptimal skewing!\n");
  }

  for (uint32_t i = 0; i < way / _num_skewing_functions; i++) {
    addr1 = hash(addr1);
  }

  return addr1;
}

int32_t SkewedAssocCache::readCl(tag_t cl, const CacheContext &context,
                                 std::list<CacheResponse> &response) {
  std::vector<cacheEntry *> vSet = getVirtualSet(cl, context);

  int32_t replaceWay = -1;
  for (size_t w = 0; w < _nWays; w++) {
    if (vSet[w]->tag == cl) {
      access(*vSet[w]);
      response.push_back(CacheResponse(true));
      return 1;
    }
    if (vSet[w]->tag == TAG_NONE)
      replaceWay = w;
  }

  if (replaceWay != -1 && _invalidFirst) {
    vSet[replaceWay]->tag = cl;
    access(*vSet[replaceWay]);
    response.push_back(CacheResponse(false));
    return 0;
  }

  switch (getAlgorithm()) {
  case REPL_LRU: {
    uint32_t oldesttime = 0;
    for (size_t w = 0; w < _nWays; w++) {
      const uint32_t time = _clock - vSet[w]->accessTime;
      if (time > oldesttime) {
        oldesttime = time;
        replaceWay = w;
      }
    }
    break;
  }
  case REPL_RANDOM:
  default:
    replaceWay = random() % _nWays;
    break;
  }
  if (vSet[replaceWay]->tag == TAG_NONE) {
    response.push_back(CacheResponse(false));
  } else {
    response.push_back(CacheResponse(false, vSet[replaceWay]->tag));
  }
  vSet[replaceWay]->tag = cl;
  access(*vSet[replaceWay]);
  return 0;
}

void SkewedAssocCache::access(cacheEntry &ce) { ce.accessTime = _clock++; }

int32_t SkewedAssocCache::evictCl(tag_t cl, const CacheContext &context,
                                  std::list<CacheResponse> &response) {
  std::vector<cacheEntry *> vSet = getVirtualSet(cl, context);

  for (size_t w = 0; w < _nWays; w++) {
    if (vSet[w]->tag == cl) {
      vSet[w]->tag = TAG_NONE;
      response.push_back(CacheResponse(true, cl));
      return 1;
    }
  }

  response.push_back(CacheResponse(false));
  return 0;
}

const char *SkewedAssocCache::getCacheType() const { return CACHE_TYPESTR; }

size_t SkewedAssocCache::getNLines() const { return _nSets * _nWays; }

tag_t SkewedAssocCache::getIdx(tag_t cl, size_t way,
                               const CacheContext &context) const {
  return skew(cl >> setShift, way) & setMask;
}

std::vector<cacheEntry *>
SkewedAssocCache::getVirtualSet(tag_t cl, const CacheContext &context) {
  std::vector<cacheEntry *> vSet(_nWays);
  for (size_t w = 0; w < _nWays; w++) {
    const tag_t idx = getIdx(cl, w, context);
    vSet[w] = &(_cacheEntries[w][idx]);
  }
  return vSet;
}

std::vector<tag_t>
SkewedAssocCache::getWayIndices(tag_t cl, const CacheContext &context) const {
  std::vector<tag_t> wayIndices(_nWays);
  for (size_t w = 0; w < _nWays; w++) {
    wayIndices[w] = getIdx(cl, w, context);
  }
  return wayIndices;
}

int32_t SkewedAssocCache::hasCollision(tag_t cl1, const CacheContext &ctx1,
                                       tag_t cl2,
                                       const CacheContext &ctx2) const {
  std::vector<tag_t> wayIndices1 = getWayIndices(cl1, ctx1);
  std::vector<tag_t> wayIndices2 = getWayIndices(cl2, ctx2);

  for (size_t w = 0; w < _nWays; w++) {
    if (wayIndices1[w] == wayIndices2[w]) {
      return 1;
    }
  }
  return 0;
}

size_t SkewedAssocCache::getNumParams() const { return 1; }

uint32_t SkewedAssocCache::getParam(size_t idx) const {
  if (idx == 0) {
    return _invalidFirst;
  }
  return 0;
}
