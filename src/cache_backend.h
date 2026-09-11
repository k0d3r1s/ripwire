#pragma once

#include <bit>

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

struct sockaddr;

namespace rw
{

inline constexpr std::uint8_t kArtifactArch =
    ( std::endian::native == std::endian::little ? 0u : 1u ) | ( sizeof( void* ) << 1 );

enum class CacheBackendKind : std::uint8_t { Disabled, File, Redis };

struct RedisCacheConfig
{
    std::string endpoint;
    std::string username;
    std::string password;
    std::string nameSpace;
    std::string project;
    std::uint32_t ttlSeconds = 30u * 24u * 60u * 60u;
    std::uint32_t timeoutMs = 1000;
    bool allowPlaintextRemote = false;
};

struct CachePolicy
{
    CacheBackendKind kind = CacheBackendKind::Disabled;
    std::string explicitFilePath;
    RedisCacheConfig redis;
};

struct CacheContext
{
    std::shared_ptr<const CachePolicy> policy;
    std::string filePath;
    std::string project;
    bool captureValueUses = true;
};

// Closed families: only immutable derived data belongs here. localPath is File-only routing.
enum class CacheBlobFamily : std::uint8_t { QualitySnapshot, QualityBody, QualityChurn, GitOracle, SpanTier, DocumentExtraction };
enum class CacheProbeStatus : std::uint8_t { Hit, Miss, Corrupt, Unavailable };

int readCacheFileBlob( const std::string& path, std::string& bytes );
bool atomicWriteCacheFile( const std::string& path, const std::string& bytes );

struct CacheBlobAddress
{
    CacheBlobFamily family;
    std::uint32_t schemeVersion;
    std::uint32_t artifactArch = kArtifactArch;
    std::string identity;
    std::string localPath;
    int ( *fileProbe )( const std::string&, std::string& ) = readCacheFileBlob;
    bool ( *fileStore )( const std::string&, const std::string& ) = atomicWriteCacheFile;
};

CacheProbeStatus probeCacheBlob( const CacheContext& cache, const CacheBlobAddress& address, std::string& bytes );
bool storeCacheBlob( const CacheContext& cache, const CacheBlobAddress& address, const std::string& bytes );

struct CacheSelectionInput
{
    bool noCache = false;
    bool cacheWasExplicit = false;
    std::string_view explicitCache;
    std::string_view environmentBackend;
};

bool resolveCachePolicy( const CacheSelectionInput& input, std::shared_ptr<const CachePolicy>& out, std::string& error );
bool cacheContextForRoot( std::shared_ptr<const CachePolicy> policy, std::string_view root,
                          bool captureValueUses, CacheContext& out, std::string& error );
std::string redisProjectIdentity( std::string_view root, std::string_view overrideValue, std::string& error );
std::string redisKeyHash( std::string_view value );
bool redisHostIsLoopback( std::string host );
bool redisAddressIsLoopback( const sockaddr* address ) noexcept;

}
