#pragma once
#if !defined( RIPWIRE_INGEST_TU )
#error "ingest_cache_redis.h is a section of ingest.cpp"
#endif

namespace rw
{
namespace
{

// All Redis users in this process share the latch and a queryable failure-class bitset. Remote bytes
// are untrusted framing, but authenticated namespace writers are trusted to produce correct facts:
// SHA-256 detects corruption and cross-project substitution, not a writer deliberately forging facts.
constexpr std::size_t kRedisIngestRecordLimit = 4u * 1024u * 1024u;
constexpr std::size_t kRedisIngestBatchItems = 16;

inline std::string redisIngestPrefix( const CacheContext& cache, bool rich )
{
    const CacheIdentity identity = cacheIdentity();
    return "ripwire:" + redisKeyHash( cache.policy->redis.nameSpace ) + ":" + redisKeyHash( cache.project )
         + ":ingest:" + std::to_string( identity.cacheVersion ) + ":" + std::to_string( parserVerFor( rich ) )
         + ":" + std::to_string( kArtifactArch ) + ( rich ? ":rich:" : ":lean:" );
}

// Fixed-width envelope: magic, SHA-256 of identity+source+record, source SHA-256, legacy checksum,
// then the unchanged v15 per-file codec. The record itself contains the expected relative path/hash.
inline std::string redisIngestEnvelope( const std::string& prefix, std::string_view sourceDigest, const EncodedCacheRecord& record )
{
    std::string envelope = "RWI1" + redisKeyHash( prefix + std::string( sourceDigest ) + record.bytes ) + std::string( sourceDigest );
    envelope.append( reinterpret_cast<const char*>( &record.sum ), sizeof( record.sum ) );
    envelope += record.bytes;
    return envelope;
}

inline bool decodeRedisIngestRecord( std::string_view envelope, const std::string& prefix, std::string_view relativePath,
                                     std::string_view sourceDigest, std::uint64_t sourceHash, bool rich, FileFacts& facts )
{
    constexpr std::size_t headerBytes = 4 + 64 + 64 + sizeof( std::uint32_t );
    if( envelope.size() <= headerBytes || envelope.size() > kRedisIngestRecordLimit || envelope.substr( 0, 4 ) != "RWI1"
        || envelope.substr( 68, 64 ) != sourceDigest )
    {
        return false;
    }
    const std::string_view record = envelope.substr( headerBytes );
    if( envelope.substr( 4, 64 ) != redisKeyHash( prefix + std::string( sourceDigest ) + std::string( record ) ) )
    {
        return false;
    }
    std::uint32_t checksum = 0;
    std::memcpy( &checksum, envelope.data() + 132, sizeof( checksum ) );
    if( recordSum32( record ) != checksum )
    {
        return false;
    }
    const CacheRecordExpectation expected{ relativePath, contentHash64( relativePath ), sourceHash, checksum, rich, false };
    CacheDecodeOutput output{ facts.defs, facts.refs, facts.incs, facts.binds, facts.ffis, facts.routeDefs, facts.routeUses,
                              facts.constOpens, facts.health, facts.sizeBytes, facts.mtimeNs, facts.ctimeNs };
    if( !decodeCacheRecord( record, expected, output ) )
    {
        return false;
    }
    facts.hash = sourceHash;
    // Foreign clocks/inodes never authorize reuse; prewarm must reread and hash the current checkout.
    facts.sizeBytes = facts.mtimeNs = facts.ctimeNs = -1;
    return true;
}

inline HashMap<std::string, FileFacts> loadRedisIngestCache( const CacheContext& cache, std::string_view rootDir, bool rich,
                                                           const std::vector<std::string>& files, CacheLoadStats& stats )
{
    HashMap<std::string, FileFacts> found;
    found.reserve( files.size() );
    stats = CacheLoadStats{};
    const RedisClient client( cache.policy->redis );
    const std::string prefix = redisIngestPrefix( cache, rich );
    const std::string ttl = std::to_string( cache.policy->redis.ttlSeconds );
    // MGET requests have bounded item count and key bytes. Transport additionally caps aggregate
    // replies; oversized hostile batches miss as a unit without allocating unbounded memory.
    for( std::size_t start = 0; start < files.size(); start += kRedisIngestBatchItems )
    {
        const std::size_t end = std::min( files.size(), start + kRedisIngestBatchItems );
        std::vector<std::string> keys, digests, paths;
        std::vector<std::uint64_t> hashes;
        std::vector<std::size_t> fileIds;
        for( std::size_t fileId = start; fileId < end; ++fileId )
        {
            std::string bytes;
            if( !readFile( files[fileId], bytes ) ) { continue; }
            const std::string pathHash = redisKeyHash( relForHash( files[fileId], rootDir ) );
            digests.push_back( redisKeyHash( bytes ) );
            hashes.push_back( contentHash64( bytes ) );
            paths.push_back( pathHash );
            fileIds.push_back( fileId );
            keys.push_back( prefix + "record:" + pathHash + ":" + digests.back() );
        }
        if( keys.empty() ) { continue; }
        std::vector<std::string_view> request{ "MGET" };
        for( const std::string& key : keys ) { request.push_back( key ); }
        const RedisResult result = client.command( request );
        if( !result || result.reply.type != RedisReplyType::Array || result.reply.elements.size() != keys.size() )
        {
            redisIngestDegraded( result ? RedisFailure::Protocol : result.failure );
            continue;
        }
        std::vector<std::vector<std::string>> refresh;
        for( std::size_t item = 0; item < keys.size(); ++item )
        {
            const RedisReply& reply = result.reply.elements[item];
            if( reply.type == RedisReplyType::Nil ) { continue; }
            FileFacts facts;
            if( reply.type != RedisReplyType::Bulk
                || !decodeRedisIngestRecord( reply.bytes, prefix, relForHash( files[fileIds[item]], rootDir ), digests[item], hashes[item], rich, facts ) )
            {
                redisIngestDegraded();
                continue;
            }
            found.emplace( files[fileIds[item]], std::move( facts ) );
            ++stats.recordsRead;
            refresh.push_back( { "EXPIRE", keys[item], ttl } );
            refresh.push_back( { "EXPIRE", prefix + "descriptor:" + paths[item], ttl } );
        }
        if( !refresh.empty() )
        {
            const RedisResult refreshed = client.pipeline( refresh );
            if( !refreshed ) { redisIngestDegraded( refreshed.failure ); }
            else if( refreshed.reply.type != RedisReplyType::Array || refreshed.reply.elements.size() != refresh.size()
                     || std::any_of( refreshed.reply.elements.begin(), refreshed.reply.elements.end(),
                                     []( const RedisReply& reply ) { return reply.type != RedisReplyType::Integer || reply.integer < 0 || reply.integer > 1; } ) )
            {
                redisIngestDegraded();
            }
        }
    }
    stats.blobEntries = stats.recordsRead;
    return found;
}

inline void saveRedisIngestCache( const CacheContext& cache, std::string_view rootDir, const std::vector<std::string>& files,
                                  const std::vector<std::string>& sourceDigests, const CacheEncodeInput& input )
{
    const RedisClient client( cache.policy->redis );
    const std::string prefix = redisIngestPrefix( cache, input.captureValueUses );
    const std::string ttl = std::to_string( cache.policy->redis.ttlSeconds );
    const CachePathKeys keys = buildCachePathKeys( files, rootDir );
    const CacheFileIndexes indexes = buildCacheFileIndexes( files.size(), input.defs, input.refs, input.incs, input.binds,
                                                           input.ffis, input.routeDefs, input.routeUses, input.constOpens );
    // One bounded record per write batch. Only successfully parsed, currently crawled files have
    // sourceDigests: hits were already refreshed and absent/excluded descriptors expire naturally.
    for( std::uint32_t fileId = 0; fileId < files.size(); ++fileId )
    {
        if( sourceDigests[fileId].empty() ) { continue; }
        const EncodedCacheRecord record = encodeCacheRecord( fileId, keys, indexes, input );
        const std::string envelope = redisIngestEnvelope( prefix, sourceDigests[fileId], record );
        if( envelope.size() > kRedisIngestRecordLimit ) { redisIngestDegraded(); continue; }
        const std::string pathHash = redisKeyHash( keys.rels[fileId] );
        const std::string key = prefix + "record:" + pathHash + ":" + sourceDigests[fileId];
        const RedisResult stored = client.command( { "SET", key, envelope, "NX", "EX", ttl } );
        if( !stored ) { redisIngestDegraded( stored.failure ); continue; }
        if( stored.reply.type == RedisReplyType::Nil )
        {
            const RedisResult existing = client.command( { "GET", key } );
            FileFacts facts;
            if( !existing || existing.reply.type != RedisReplyType::Bulk
                || !decodeRedisIngestRecord( existing.reply.bytes, prefix, keys.rels[fileId], sourceDigests[fileId],
                                             input.fileHash[fileId], input.captureValueUses, facts ) )
            {
                redisIngestDegraded( existing ? RedisFailure::Protocol : existing.failure );
                continue;
            }
        }
        else if( stored.reply.type != RedisReplyType::Simple || stored.reply.bytes != "OK" )
        {
            redisIngestDegraded();
            continue;
        }
        const std::string descriptorKey = prefix + "descriptor:" + pathHash;
        const RedisResult descriptor = client.command( { "SET", descriptorKey, sourceDigests[fileId], "EX", ttl } );
        if( !descriptor || descriptor.reply.type != RedisReplyType::Simple || descriptor.reply.bytes != "OK" )
        {
            redisIngestDegraded( descriptor ? RedisFailure::Protocol : descriptor.failure );
        }
    }
}

// Shared dispatch keeps the parse-pool's dirty decision independent of backend serialization.
inline void saveIngestCache( const CacheContext& cache, std::string_view rootDir, const std::vector<std::string>& files,
                             const std::vector<std::string>& sourceDigests, const CacheEncodeInput& input )
{
    if( !cache.policy ) { return; }
    if( cache.policy->kind == CacheBackendKind::File && !cache.filePath.empty() )
    {
        saveCache( cache.filePath, rootDir, files, input.fileHash, input.fileSize, input.fileMtime, input.fileCtime,
                   input.fileHealth, input.defs, input.refs, input.incs, input.binds, input.ffis, input.routeDefs,
                   input.routeUses, input.constOpens, input.captureValueUses );
    }
    else if( cache.policy->kind == CacheBackendKind::Redis )
    {
        saveRedisIngestCache( cache, rootDir, files, sourceDigests, input );
    }
}

} // namespace
} // namespace rw
