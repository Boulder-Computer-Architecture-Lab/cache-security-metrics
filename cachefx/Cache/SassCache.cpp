/*
 * SassCache.cpp
 *
 * Adapted from the artifact: SoK: So, You Think You Know All About Secure Randomized Caches?
 * 
 */

#include <Cache/SassCache.h>
#include "crypto/speck.h"
#include <iostream>
#include <cmath>

const char *SassCache::CACHE_TYPESTR = "sasscache";

SassCache::SassCache(size_t sets, size_t ways, size_t partitions)
  : _nSets(sets), _nWays(ways), _nPartitions(partitions), _invalidFirst(false) {
    if ((_nWays %_nPartitions) != 0) {
      _nPartitions = 1;
    }
    
    _nSetsBits = log2(_nSets);
    
    _cacheEntries.resize(_nWays);
    for (size_t w = 0; w < _nWays; w++) {
      _cacheEntries[w].resize(_nSets);
      for (size_t s = 0; s < _nSets; s++) {
        _cacheEntries[w][s].tag = TAG_INIT;
        _cacheEntries[w][s].accessTime = 0;
        _cacheEntries[w][s].flags = 0;
      }
    }
    
  initKeys();
}

void SassCache::initKeys()
{
  uint64_t K[] = {0x06FADE6001020304, 0x01020304CAB4BEEF};

  _keyId0 = new uint64_t[32];
  _keyId1 = new uint64_t[32];
  _keyIdOther = new uint64_t[32];

  speck128ExpandKey(K, _keyId0);
  K[0] ^= 0x1234ABCD1234ABCD;
  speck128ExpandKey(K, _keyId1);
  K[0] ^= 0x1234ABCD1234ABCD ^ 0xBCDE789ABCDE789A;
  speck128ExpandKey(K, _keyIdOther);
}

SassCache::~SassCache() {
  delete _keyId0;
  delete _keyId1;
  delete _keyIdOther;
}

int SassCache::readCl(tag_t cl, const CacheContext& context, std::list<CacheResponse>& response) {
  std::vector<cacheEntry*> vSet = getVirtualSet(cl, context);

  int replaceWay = -1;
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

  replaceWay = random() % _nWays;
  if (vSet[replaceWay]->tag == TAG_NONE) {
    response.push_back(CacheResponse(false));
  } else {
    response.push_back(CacheResponse(false, vSet[replaceWay]->tag));
  }
  vSet[replaceWay]->tag = cl;
  access(*vSet[replaceWay]);
  return 0;
}

int SassCache::evictCl(tag_t cl, const CacheContext& context, std::list<CacheResponse>& response) {
  std::vector<cacheEntry*> vSet = getVirtualSet(cl, context);

  for (int w = 0; w < _nWays; w++) {
    if (vSet[w]->tag == cl) {
      vSet[w]->tag = TAG_NONE;
      response.push_back(CacheResponse(true, cl));
      return 1;
    }
  }

  response.push_back(CacheResponse(false));
  return 0;
}

const char* SassCache::getCacheType() const {
  return CACHE_TYPESTR;
}

size_t SassCache::getNLines() const {
  return _nSets * _nWays;
}

size_t SassCache::getNWays() const {
  return _nWays;
}

size_t SassCache::getNSets() const {
  return _nSets;
}

std::vector<cacheEntry*> SassCache::getVirtualSet(tag_t cl, const CacheContext& context) {
  std::vector<tag_t> indices = getWayIndices(cl, context);
  std::vector<cacheEntry*> vSet(_nWays);
  for (size_t w = 0; w < _nWays; w++) {
    vSet[w] = &(_cacheEntries[w][indices[w]]);
  }
  return vSet;
}

std::vector<tag_t> SassCache::getWayIndices(tag_t cl, const CacheContext& context) const {
	uint64_t v[16], tweak;
	uint64_t c[2];
	uint64_t nSetsMask = (1 << _nSetsBits) - 1;
  uint64_t nSetsMaskWithT = (1 << (_nSetsBits + coverageBit)) - 1;
	uint64_t indicesPerBlock = (uint64_t) floor((double) 128 / (_nSetsBits + coverageBit));
	uint32_t round1Iterations = (uint32_t) ceil(
			(double) _nPartitions / indicesPerBlock);

	uint64_t *key = _keyIdOther;

	if (context.getCoreId() == 0) {
		key = _keyId0;
	} else if (context.getCoreId() == 1){
		key = _keyId1;
	}

	// Round 1
	for (uint32_t i = 0; i < round1Iterations; i++) {
		v[2 * i] = cl & 0xFFFFFFFFFFFFFFFF;
		v[2 * i + 1] = i;
		speck128Encrypt(v + 2 * i, v + 2 * i + 1, key);
	}

	// Round 2

	std::vector<tag_t> wayIndices(_nWays);
	int partitionSize = (_nWays / _nPartitions);
	size_t p = 0;

	for (size_t oBlock = 0; oBlock < round1Iterations; oBlock++) {
		for (size_t iBlock = 0; iBlock < indicesPerBlock; iBlock++) {
			c[0] = (v[2 * oBlock] >> (iBlock * (_nSetsBits + coverageBit))) & nSetsMaskWithT;
			c[1] = p;
			speck128Encrypt(c, c + 1, key);
			tag_t idx = c[0] & nSetsMask;
			for (size_t w = 0; w < partitionSize; w++)
				wayIndices[p * partitionSize + w] = idx;
			p++;
			if (p == _nPartitions) {
				return wayIndices;
			}
		}
	}

	return wayIndices;
}

int SassCache::hasCollision(tag_t cl1, const CacheContext& ctx1, tag_t cl2, const CacheContext& ctx2) const {
  std::vector<tag_t> wayIndices1 = getWayIndices(cl1, ctx1);
  std::vector<tag_t> wayIndices2 = getWayIndices(cl2, ctx2);

  for (int w = 0; w < _nWays; w++) {
    if (wayIndices1[w] == wayIndices2[w]) {
      return 1;
    }
  }
  return 0;
}

size_t SassCache::getNumParams() const {
  return 2;
}

unsigned SassCache::getParam(size_t idx) const {
  if (idx == 0) {
    return _nPartitions;
  } else if (idx == 1) {
    return _invalidFirst;
  }
  return 0;
}

