#ifndef MIRAGE_H_
#define MIRAGE_H_

#include <Cache/AssocCache.h>

#include <cstdint>
#include <limits>
#include <queue>
#include <random>
#include <vector>

class MIRAGE : public Cache {
public:
  static const char *CACHE_TYPESTR;

  enum DataReplPolicy {
    DATA_REPL_RANDOM = 0,
    DATA_REPL_REUSE = 1
  };

private:
  inline static constexpr size_t INVALID_DATA =
      std::numeric_limits<size_t>::max();

  inline static constexpr uint8_t DATA_REUSE_MIN = 0;
  inline static constexpr uint8_t DATA_REUSE_MAX = 3;

  struct TagLocation {
    size_t way;
    size_t set;
    bool valid;

    TagLocation()
        : way(0), set(0), valid(false) {}

    TagLocation(size_t w, size_t s)
        : way(w), set(s), valid(true) {}
  };

  std::vector<std::vector<cacheEntry>> _cacheEntries;

  std::vector<std::vector<size_t>> _tagToData;

  std::vector<TagLocation> _dataToTag;

  std::vector<uint8_t> _dataReuse;

  std::queue<size_t> _vacantData;

  size_t _nSets;

  size_t _nDataWays;

  size_t _nTagWays;

  size_t _nPartitions;

  double _tdr;

  bool _invalidFirst;

  uint32_t *_key;

  std::mt19937_64 _rng;

  size_t _dataReuseVictimID;

  DataReplPolicy _dataReplPolicy;

  uint32_t _clock;

public:

  MIRAGE(size_t sets, size_t ways) : MIRAGE(sets, ways, 1, 1.75) {}
  MIRAGE(size_t sets, size_t ways, size_t partitions) : MIRAGE(sets, ways, partitions, 1.75) {}
  MIRAGE(size_t sets, size_t ways, size_t partitions, double tdr);

  virtual ~MIRAGE();

  virtual const char *getCacheType() const;

  size_t getNLines() const override;

  size_t getNWays() const override;

  size_t getNSets() const override;

  size_t getEvictionSetSize() const override {
    return _nTagWays;
  }

  size_t getGHMGroupSize() const override {
    return _nTagWays;
  }

  size_t getNumParams() const override;
  uint32_t getParam(size_t idx) const override;

  int32_t getNPartitions() const {
    return static_cast<int32_t>(_nPartitions);
  }

  size_t getNDataWays() const { return _nDataWays; }

  size_t getNTagWays() const { return _nTagWays; }

  double getTDR() const { return _tdr; }

  bool getInvalidFirst() const { return _invalidFirst; }

  void setInvalidFirst(bool invalidFirst) { _invalidFirst = invalidFirst; }

  void setDataReplPolicy(DataReplPolicy policy) { _dataReplPolicy = policy; }

  int32_t hasCollision(tag_t cl1, const CacheContext &ctx1, tag_t cl2, const CacheContext &ctx2) const override;

protected:
  int32_t readCl(tag_t cl, const CacheContext &context, std::list<CacheResponse> &response) override;

  int32_t evictCl(tag_t cl, const CacheContext &context, std::list<CacheResponse> &response) override;

private:
  virtual tag_t getIdx(tag_t cl, size_t partition) const;

  virtual void access(cacheEntry &ce);

  virtual std::vector<cacheEntry *> getVirtualSet(tag_t cl);

  virtual std::vector<tag_t> getWayIndices(tag_t cl) const;

  size_t selectTagVictim(const std::vector<tag_t> &wayIndices);

  size_t selectDataVictim();

  size_t dessociateTag(size_t way, size_t set);

  void associateTag(size_t way, size_t set, size_t dataID, tag_t tag, const CacheContext &context);

  void initKeys();
};

#endif /* MIRAGE_H_ */