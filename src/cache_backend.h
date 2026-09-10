#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

namespace rw
{

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

}
