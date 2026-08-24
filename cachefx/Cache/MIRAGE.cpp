/*
 * Copyright 2022 The University of Adelaide
 *
 * This file is part of CacheFX.
 *
 * Created on: Feb 24, 2020
 *     Author: thomas
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <Cache/MIRAGE.h>

#include <crypto/speck.h>

#include <cassert>
#include <cmath>
#include <cstdint>
#include <stdexcept>

const char *MIRAGE::CACHE_TYPESTR = "mirage";

MIRAGE::MIRAGE(size_t sets, size_t ways, size_t partitions, double tdr)
	: _nSets(sets), _nDataWays(ways), _nTagWays(0), _nPartitions(partitions),
		_tdr(tdr), _invalidFirst(true), _key(nullptr), _rng(42),
    _dataReuseVictimID(0), _dataReplPolicy(DATA_REPL_RANDOM), _clock(0)
{
  assert(_nSets > 0);
  assert(_nDataWays > 0);
  assert(_tdr >= 1.0 || _tdr <= 2.0);

  if (_nPartitions == 0) {
    _nPartitions = 1;
  }

  _nTagWays = static_cast<size_t>(std::floor(_tdr * static_cast<double>(_nDataWays)));

  if (_nTagWays < _nDataWays) {
    _nTagWays = _nDataWays;
  }

  if ((_nTagWays % _nPartitions) != 0) {
    _nPartitions = 1;
  }

  _cacheEntries.resize(_nTagWays);
  _tagToData.resize(_nTagWays);

  for (size_t w = 0; w < _nTagWays; ++w) {
    _cacheEntries[w].resize(_nSets);
    _tagToData[w].resize(_nSets, INVALID_DATA);

    for (size_t s = 0; s < _nSets; ++s) {
      _cacheEntries[w][s].tag = TAG_NONE;
      _cacheEntries[w][s].accessTime = 0;
      _cacheEntries[w][s].flags = 0;
      _cacheEntries[w][s].context =
          DEFAULT_CACHE_CONTEXT;
    }
  }

  const size_t numDataBlocks = _nSets * _nDataWays;

  _dataToTag.resize(numDataBlocks);
  _dataReuse.resize(numDataBlocks, DATA_REUSE_MIN);

  for (size_t i = 0; i < numDataBlocks; ++i) {
    _vacantData.push(i);
  }

  initKeys();
}

void
MIRAGE::initKeys()
{
  uint32_t K[] = {
		0x06FADE60,
		0xCAB4BEEF,
		0x04866840,
		0x80866808
  };

  _key = new uint32_t[27];

  speck64ExpandKey(K, _key);
}

MIRAGE::~MIRAGE()
{
  delete[] _key;
}

void MIRAGE::associateTag(size_t way, size_t set, size_t dataID, tag_t tag, const CacheContext &context) {
  assert(way < _nTagWays);
  assert(set < _nSets);
  assert(dataID < _dataToTag.size());

  assert(_cacheEntries[way][set].tag == TAG_NONE);
  assert(_tagToData[way][set] == INVALID_DATA);
  assert(!_dataToTag[dataID].valid);

  _cacheEntries[way][set].tag = tag;
  _cacheEntries[way][set].context = context;

  _tagToData[way][set] = dataID;

  _dataToTag[dataID].way = way;
  _dataToTag[dataID].set = set;
  _dataToTag[dataID].valid = true;

  _dataReuse[dataID] = DATA_REUSE_MIN;

  access(_cacheEntries[way][set]);
}

size_t MIRAGE::dessociateTag(size_t way, size_t set) {
  assert(way < _nTagWays);
  assert(set < _nSets);

  const size_t dataID = _tagToData[way][set];

  assert(dataID != INVALID_DATA);
  assert(dataID < _dataToTag.size());
  assert(_dataToTag[dataID].valid);

  _cacheEntries[way][set].tag = TAG_NONE;
	_tagToData[way][set] = INVALID_DATA;
	_dataToTag[dataID].valid = false;
	_dataReuse[dataID] = DATA_REUSE_MIN;

	return dataID;
}

size_t MIRAGE::selectTagVictim(const std::vector<tag_t> &wayIndices) {
  assert(wayIndices.size() == _nTagWays);

  if (_invalidFirst) {
    for (size_t w = 0; w < _nTagWays; ++w) {
      const size_t set = static_cast<size_t>(wayIndices[w]);
      if (_cacheEntries[w][set].tag == TAG_NONE) {
        return w;
      }
    }
  }

  return static_cast<size_t>(_rng() % _nTagWays);
}

size_t
MIRAGE::selectDataVictim() {
  assert(_vacantData.empty());
  assert(!_dataToTag.empty());

  size_t dataVictim = INVALID_DATA;

  if (_dataReplPolicy == DATA_REPL_RANDOM) {
    dataVictim = static_cast<size_t>(_rng() % _dataToTag.size());
  } else if (_dataReplPolicy == DATA_REPL_REUSE) {
    size_t numAttempts = 0;
    while (_dataReuse[_dataReuseVictimID] != DATA_REUSE_MIN) {
      assert(_dataReuse[_dataReuseVictimID] <= DATA_REUSE_MAX);
      --_dataReuse[_dataReuseVictimID];
      _dataReuseVictimID = (_dataReuseVictimID + 1) % _dataToTag.size();
      ++numAttempts;
      if (numAttempts >= 40) {
				break;
      }
    }
    dataVictim = _dataReuseVictimID;
    _dataReuseVictimID = (_dataReuseVictimID + 1) % _dataToTag.size();
  } else {
    assert(false);
  }

  assert(dataVictim != INVALID_DATA);
  assert(dataVictim < _dataToTag.size());
  assert(_dataToTag[dataVictim].valid);

  return dataVictim;
}

int32_t MIRAGE::readCl(tag_t cl, const CacheContext &context, std::list<CacheResponse> &response) {
  const std::vector<tag_t> wayIndices = getWayIndices(cl);

	// hit
  for (size_t w = 0; w < _nTagWays; ++w) {
    const size_t set = static_cast<size_t>(wayIndices[w]);

    cacheEntry &entry = _cacheEntries[w][set];

    if (entry.tag == cl) {
      const size_t dataID = _tagToData[w][set];

      assert(dataID != INVALID_DATA);
      assert(dataID < _dataReuse.size());

      if (_dataReuse[dataID] < DATA_REUSE_MAX) {
        ++_dataReuse[dataID];
      }

      access(entry);
      response.push_back(CacheResponse(true));
      return 1;
    }
  }

	// miss
  const size_t victimWay = selectTagVictim(wayIndices);
  const size_t victimSet = static_cast<size_t>(wayIndices[victimWay]);
  cacheEntry &tagVictim = _cacheEntries[victimWay][victimSet];
  size_t dataID = INVALID_DATA;
  bool eviction = false;
  tag_t evictedTag = TAG_NONE;

	// scenario A
	if (tagVictim.tag == TAG_NONE && !_vacantData.empty()) {
    dataID = _vacantData.front();
    _vacantData.pop();
	// scenario B
  } else if (tagVictim.tag != TAG_NONE) {
    eviction = true;
    evictedTag = tagVictim.tag;
    dataID = dessociateTag(victimWay, victimSet);
	// scenario C
  } else {
    assert(tagVictim.tag == TAG_NONE);
    assert(_vacantData.empty());

    dataID = selectDataVictim();

    assert(dataID < _dataToTag.size());

    const TagLocation oldLocation = _dataToTag[dataID];

    assert(oldLocation.valid);

    cacheEntry &dataVictimTag = _cacheEntries[oldLocation.way][oldLocation.set];
    assert(dataVictimTag.tag != TAG_NONE);

    eviction = true;
    evictedTag = dataVictimTag.tag;

    const size_t dessociatedDataID = dessociateTag(oldLocation.way, oldLocation.set);
    assert(dessociatedDataID == dataID);
  }

  assert(dataID != INVALID_DATA);

  associateTag(victimWay, victimSet, dataID, cl, context);

  if (eviction) {
    response.push_back(CacheResponse(false,evictedTag));
  } else {
    response.push_back(CacheResponse(false));
  }

  return 0;
}

int32_t MIRAGE::evictCl(tag_t cl, const CacheContext &context, std::list<CacheResponse> &response) {
  const std::vector<tag_t> wayIndices = getWayIndices(cl);

  for (size_t w = 0; w < _nTagWays; ++w) {
    const size_t set = static_cast<size_t>(wayIndices[w]);

    if (_cacheEntries[w][set].tag == cl) {

      const size_t dataID = dessociateTag(w, set);
      assert(dataID != INVALID_DATA);
      _vacantData.push(dataID);
      response.push_back(CacheResponse(true, cl));
      return 1;
    }
  }

  response.push_back(CacheResponse(false));

  return 0;
}

const char * MIRAGE::getCacheType() const
{
  return CACHE_TYPESTR;
}

size_t MIRAGE::getNLines() const
{
  return _nSets * _nDataWays;
}

size_t MIRAGE::getNWays() const
{
  return _nTagWays;
}

size_t MIRAGE::getNSets() const
{
  return _nSets;
}

tag_t MIRAGE::getIdx(tag_t cl, size_t partition) const {
  uint64_t value = static_cast<uint64_t>(cl);

  const uint64_t tweak = (static_cast<uint64_t>(partition & 0xFF)) * 0x0101010101010101ULL;

  value ^= tweak;

  uint32_t low = static_cast<uint32_t>(value & 0xFFFFFFFFULL);
  uint32_t high = static_cast<uint32_t>(value >> 32);

  speck64Encrypt(&low, &high, _key);

  value = static_cast<uint64_t>(low) | (static_cast<uint64_t>(high) << 32);

  value ^= tweak;

  return static_cast<tag_t>(value % _nSets);
}

std::vector<cacheEntry *> MIRAGE::getVirtualSet(tag_t cl) {
  std::vector<cacheEntry *> vSet(_nTagWays);

  const size_t partitionSize = _nTagWays / _nPartitions;

  for (size_t p = 0; p < _nPartitions; ++p) {
    const tag_t idx = getIdx(cl, p);
    for (size_t w = 0; w < partitionSize; ++w) {
      const size_t tagWay = p * partitionSize + w;
      vSet[tagWay] = &_cacheEntries[tagWay][idx];
    }
  }

  return vSet;
}

std::vector<tag_t> MIRAGE::getWayIndices(tag_t cl) const {
  std::vector<tag_t> wayIndices(_nTagWays);

  const size_t partitionSize = _nTagWays / _nPartitions;

  for (size_t p = 0; p < _nPartitions; ++p) {
    const tag_t idx = getIdx(cl, p);

    for (size_t w = 0; w < partitionSize; ++w) {
      wayIndices[p * partitionSize + w] = idx;
    }
  }

  return wayIndices;
}

void MIRAGE::access(cacheEntry &ce) {
  ce.accessTime = _clock++;
}

int32_t MIRAGE::hasCollision(tag_t cl1, const CacheContext &ctx1, tag_t cl2, const CacheContext &ctx2) const
{
  const std::vector<tag_t> wayIndices1 = getWayIndices(cl1);

  const std::vector<tag_t> wayIndices2 = getWayIndices(cl2);

  for (size_t w = 0; w < _nTagWays; ++w) {
    if (wayIndices1[w] == wayIndices2[w]) {
      return 1;
    }
  }

  return 0;
}

size_t MIRAGE::getNumParams() const {
  return 2;
}

uint32_t MIRAGE::getParam(size_t idx) const {
  if (idx == 0) {
    return static_cast<uint32_t>(_nPartitions);
  }

  if (idx == 1) {
    return static_cast<uint32_t>(_invalidFirst);
  }

  return 0;
}
