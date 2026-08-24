/*
 * SassCache.h
 *
 *  Created on: Jan 19, 2021
 *      Author: thomas
 */

#ifndef SASSCACHE_H_
#define SASSCACHE_H_

#include <memory>
#include <vector>
#include "AssocCache.h"

class SassCache: public Cache {
public:
  static const char *CACHE_TYPESTR;
protected:
  std::vector<std::vector<cacheEntry>> _cacheEntries;
  size_t _nSets;
  size_t _nSetsBits;
  size_t _nWays;
  size_t _nPartitions;
  bool _invalidFirst;

  uint64_t *_keyId0;
  uint64_t *_keyId1;
  uint64_t *_keyIdOther;

public:
  SassCache(size_t sets, size_t ways) : SassCache(sets, ways, 1) {};
  SassCache(size_t sets, size_t ways, size_t partitions);
  virtual ~SassCache();

  virtual const char* getCacheType() const;
  size_t getNLines() const override ;
  size_t getNWays() const override;
  size_t getNSets() const override;
  size_t getEvictionSetSize() const override { return _nWays; };
  size_t getGHMGroupSize() const override { return _nWays; };
  bool getLoadBalancing() const { return false; };
  size_t getNInvalidWays() const { return 0; };

  size_t getNumParams() const override;
  unsigned getParam(size_t idx) const override;

  // New addition - Coverage bit
  int coverageBit = -1;
  // End of new addition

  int getNPartitions() const { return _nPartitions; }
  bool getInvalidFirst() const { return _invalidFirst; };
  void setInvalidFirst(bool invalidFirst) { _invalidFirst = invalidFirst; };

  int hasCollision(tag_t cl1, const CacheContext& ctx1, tag_t cl2, const CacheContext& ctx2) const override;

protected:
  int readCl(tag_t cl, const CacheContext& context, std::list<CacheResponse>& response) override;
  int evictCl(tag_t cl, const CacheContext& context, std::list<CacheResponse>& response) override;

  virtual void access(cacheEntry &ce) { };
  virtual std::vector<cacheEntry*> getVirtualSet(tag_t cl, const CacheContext& context);
  virtual std::vector<tag_t> getWayIndices(tag_t cl, const CacheContext& context) const;
  void initKeys();
};

#endif /* SASSCACHE_H_ */
