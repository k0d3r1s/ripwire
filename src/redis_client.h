#pragma once

#include "cache_backend.h"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace rw
{

enum class RedisReplyType : std::uint8_t { Simple, Error, Integer, Bulk, Nil, Array };
enum class RedisFailure : std::uint8_t { None, Config, Connect, Timeout, Protocol, Auth, ClusterRedirect, Server };

struct RedisReply
{
    RedisReplyType type = RedisReplyType::Nil;
    std::string bytes;
    std::int64_t integer = 0;
    std::vector<RedisReply> elements;
};

struct RedisResult
{
    RedisFailure failure = RedisFailure::None;
    RedisReply reply;
    std::string diagnostic;

    explicit operator bool() const noexcept { return failure == RedisFailure::None; }
};

struct RedisClientTestPeer;

class RedisClient
{
  public:
    explicit RedisClient( RedisCacheConfig config );

    [[nodiscard]] RedisResult command( const std::vector<std::string_view>& arguments ) const;
    [[nodiscard]] RedisResult pipeline( const std::vector<std::vector<std::string>>& commands ) const;

  private:
    friend struct RedisClientTestPeer;

    static RedisResult parseReplyForTesting( std::string_view bytes, std::size_t aggregateLimit = 128u * 1024u * 1024u );
    static RedisResult parseReplyChunksForTesting( const std::vector<std::string_view>& chunks );
    [[nodiscard]] RedisResult execute( const std::vector<std::vector<std::string_view>>& commands ) const;

    RedisCacheConfig config_;
};

}
