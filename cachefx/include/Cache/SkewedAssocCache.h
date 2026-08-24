#ifndef __SKEWEDASSOCCACHE_H__
#define __SKEWEDASSOCCACHE_H__

#include "AssocCache.h"
#include <memory>
#include <vector>

class SkewedAssocCache : public Cache {
public:
  static const char *CACHE_TYPESTR;

private:
  std::vector<std::vector<cacheEntry>> _cacheEntries;
  size_t _nSets;
  size_t _nWays;
  bool _invalidFirst;
  replAlg _algorithm;
  uint32_t _clock;
  size_t msbShift;
  size_t _num_skewing_functions;
  const int setShift;
  const unsigned setMask;

public:
  SkewedAssocCache(size_t sets, size_t ways);
  SkewedAssocCache(replAlg algorithm, size_t sets, size_t ways);
  virtual ~SkewedAssocCache();

  const char *getCacheType() const override;
  size_t getNLines() const override;

  size_t getNSets() const override { return _nSets; };
  size_t getNWays() const override { return _nWays; };
  size_t getEvictionSetSize() const override { return _nWays; };
  size_t getGHMGroupSize() const override { return _nWays; };
  replAlg getAlgorithm() const override { return _algorithm; }

  size_t getNumParams() const override;
  uint32_t getParam(size_t idx) const override;

  bool getInvalidFirst() const { return _invalidFirst; };
  void setInvalidFirst(bool invalidFirst) { _invalidFirst = invalidFirst; };

  int32_t hasCollision(tag_t cl1, const CacheContext &ctx1, tag_t cl2,
                       const CacheContext &ctx2) const override;

protected:
  int32_t readCl(tag_t cl, const CacheContext &context,
                 std::list<CacheResponse> &response) override;
  int32_t evictCl(tag_t cl, const CacheContext &context,
                  std::list<CacheResponse> &response) override;

private:
  virtual tag_t getIdx(tag_t cl, size_t way, const CacheContext &context) const;
  virtual void access(cacheEntry &ce);
  virtual std::vector<cacheEntry *> getVirtualSet(tag_t cl,
                                                  const CacheContext &context);
  virtual std::vector<tag_t> getWayIndices(tag_t cl,
                                           const CacheContext &context) const;

  tag_t hash(const tag_t addr) const;
  tag_t dehash(const tag_t addr) const;
  tag_t skew(const tag_t addr, const size_t way) const;
  tag_t deskew(const tag_t addr, const size_t way) const;
};

#endif /* __SKEWEDASSOCCACHE_H__ */
