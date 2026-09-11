#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include <doctest/doctest.h>

#include "redis_client.h"

#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace rw
{

struct RedisClientTestPeer
{
    static RedisResult parse( const std::string_view bytes )
    {
        return RedisClient::parseReplyForTesting( bytes );
    }

    static RedisResult parseWithAggregateLimit( const std::string_view bytes, const std::size_t limit )
    {
        return RedisClient::parseReplyForTesting( bytes, limit );
    }

    static RedisResult parseChunks( const std::vector<std::string_view>& chunks )
    {
        return RedisClient::parseReplyChunksForTesting( chunks );
    }

    static bool encodedBatchSize( const std::vector<std::vector<std::string_view>>& commands, std::size_t& size )
    {
        return RedisClient::encodedBatchSizeForTesting( commands, size );
    }
};

}

namespace
{

rw::RedisResult parse( const std::string_view bytes )
{
    return rw::RedisClientTestPeer::parse( bytes );
}

void checkProtocolFailure( const std::string_view bytes )
{
    const rw::RedisResult result = parse( bytes );
    CHECK_FALSE( result );
    CHECK( result.failure == rw::RedisFailure::Protocol );
    CHECK( result.diagnostic == "redis reply: protocol" );
}

}

TEST_CASE( "RESP2 scalar replies preserve exact values" )
{
    const rw::RedisResult simple = parse( "+PONG\r\n" );
    REQUIRE( simple );
    CHECK( simple.reply.type == rw::RedisReplyType::Simple );
    CHECK( simple.reply.bytes == "PONG" );

    const rw::RedisResult error = parse( "-ERR unavailable\r\n" );
    CHECK_FALSE( error );
    CHECK( error.failure == rw::RedisFailure::Server );
    CHECK( error.reply.type == rw::RedisReplyType::Error );
    CHECK( error.reply.bytes == "ERR unavailable" );
    CHECK( error.diagnostic == "redis reply: server ERR" );

    const rw::RedisResult integer = parse( ":-9223372036854775808\r\n" );
    REQUIRE( integer );
    CHECK( integer.reply.type == rw::RedisReplyType::Integer );
    CHECK( integer.reply.integer == std::numeric_limits<std::int64_t>::min() );

    const rw::RedisResult nil = parse( "$-1\r\n" );
    REQUIRE( nil );
    CHECK( nil.reply.type == rw::RedisReplyType::Nil );
}

TEST_CASE( "RESP2 bulk replies are binary safe" )
{
    const rw::RedisResult empty = parse( "$0\r\n\r\n" );
    REQUIRE( empty );
    CHECK( empty.reply.type == rw::RedisReplyType::Bulk );
    CHECK( empty.reply.bytes.empty() );

    const std::string binary( "a\0b", 3 );
    const std::string frame = "$3\r\n" + binary + "\r\n";
    const rw::RedisResult result = parse( frame );
    REQUIRE( result );
    CHECK( result.reply.type == rw::RedisReplyType::Bulk );
    CHECK( result.reply.bytes == binary );
}

TEST_CASE( "RESP2 arrays retain nesting and nil elements" )
{
    constexpr char frameBytes[] = "*4\r\n+OK\r\n:7\r\n$-1\r\n*2\r\n$0\r\n\r\n$3\r\na\0b\r\n";
    const std::string frame( frameBytes, sizeof( frameBytes ) - 1 );
    const rw::RedisResult result = parse( frame );
    REQUIRE( result );
    REQUIRE( result.reply.type == rw::RedisReplyType::Array );
    REQUIRE( result.reply.elements.size() == 4 );
    CHECK( result.reply.elements[0].bytes == "OK" );
    CHECK( result.reply.elements[1].integer == 7 );
    CHECK( result.reply.elements[2].type == rw::RedisReplyType::Nil );
    REQUIRE( result.reply.elements[3].elements.size() == 2 );
    CHECK( result.reply.elements[3].elements[0].bytes.empty() );
    CHECK( result.reply.elements[3].elements[1].bytes == std::string( "a\0b", 3 ) );
}

TEST_CASE( "RESP2 parser rejects truncation and trailing bytes" )
{
    for( const std::string_view frame : std::array<std::string_view, 7>{ "+OK", ":1\r", "$3\r\nab", "$3\r\nabc\r", "*1\r\n", "*2\r\n+OK\r\n", "+OK\r\ngarbage" } )
    {
        CAPTURE( frame );
        checkProtocolFailure( frame );
    }
}

TEST_CASE( "RESP2 parser accepts frames split at arbitrary receive boundaries" )
{
    const std::string binaryTail( "\0b\r\n", 4 );
    const rw::RedisResult result = rw::RedisClientTestPeer::parseChunks( { "*2\r", "\n$3\r\na", binaryTail, ":9\r", "\n" } );
    REQUIRE( result );
    REQUIRE( result.reply.elements.size() == 2 );
    CHECK( result.reply.elements[0].bytes == std::string( "a\0b", 3 ) );
    CHECK( result.reply.elements[1].integer == 9 );
}

TEST_CASE( "RESP2 parser rejects invalid prefixes and numeric fields" )
{
    for( const std::string_view frame : std::array<std::string_view, 10>{ "!nope\r\n", "\r\n", "$-2\r\n", "*-2\r\n", "$+1\r\na\r\n", ":+1\r\n",
                                                                                 "$18446744073709551616\r\n", "*18446744073709551616\r\n", ":9223372036854775808\r\n",
                                                                                 ":-9223372036854775809\r\n" } )
    {
        CAPTURE( frame );
        checkProtocolFailure( frame );
    }
}

TEST_CASE( "RESP2 parser enforces bulk array depth and node ceilings" )
{
    checkProtocolFailure( "$67108865\r\n" );
    checkProtocolFailure( "*4097\r\n" );
    checkProtocolFailure( "*1\r\n*1\r\n*1\r\n*1\r\n*1\r\n+OK\r\n" );

    std::string manyNodes = "*4096\r\n";
    for( std::size_t i = 0; i < 4096; ++i )
    {
        manyNodes += "*4\r\n:1\r\n:2\r\n:3\r\n:4\r\n";
    }
    checkProtocolFailure( manyNodes );
}

TEST_CASE( "RESP2 aggregate accounting includes framing and containers" )
{
    const rw::RedisResult result = rw::RedisClientTestPeer::parseWithAggregateLimit( "*2\r\n$3\r\nabc\r\n$3\r\ndef\r\n", 24 );
    CHECK_FALSE( result );
    CHECK( result.failure == rw::RedisFailure::Protocol );
}

TEST_CASE( "RESP2 accepts the maximum legal bulk and rejects one byte more" )
{
    constexpr std::size_t maximum = 64u * 1024u * 1024u;
    std::string frame = "$67108864\r\n";
    frame.reserve( maximum + 32 );
    frame.append( maximum, 'x' );
    frame += "\r\n";
    {
        const rw::RedisResult result = parse( frame );
        REQUIRE( result );
        REQUIRE( result.reply.type == rw::RedisReplyType::Bulk );
        CHECK( result.reply.bytes.size() == maximum );
        CHECK( result.reply.bytes.front() == 'x' );
        CHECK( result.reply.bytes.back() == 'x' );
    }
    // A complete oversized frame distinguishes the ceiling from an ordinary truncated reply.
    // Reuse the backing allocation so the gate never needs two large payloads at once.
    frame[8] = '5';
    frame.insert( frame.size() - 2, 1, 'x' );
    checkProtocolFailure( frame );
    // A complete small reply straddles the aggregate ceiling, including container allocation.
    constexpr std::string_view small = "*1\r\n$3\r\nabc\r\n";
    const std::size_t exact = small.size() + 2 * sizeof( rw::RedisReply );
    CHECK( rw::RedisClientTestPeer::parseWithAggregateLimit( small, exact ) );
    CHECK_FALSE( rw::RedisClientTestPeer::parseWithAggregateLimit( small, exact - 1 ) );
}

TEST_CASE( "RESP2 redirects have a dedicated deterministic failure" )
{
    for( const std::string_view frame : { "-MOVED 1 127.0.0.1:6379\r\n", "-ASK 1 127.0.0.1:6379\r\n" } )
    {
        const rw::RedisResult result = parse( frame );
        CHECK_FALSE( result );
        CHECK( result.failure == rw::RedisFailure::ClusterRedirect );
        CHECK( result.diagnostic == "redis reply: cluster redirect" );
    }
}

TEST_CASE( "outbound batch ceilings fail before transport" )
{
    rw::RedisCacheConfig config;
    config.endpoint = "redis://127.0.0.1:1/0";
    config.timeoutMs = 1;
    const rw::RedisClient client( config );

    std::vector<std::vector<std::string>> tooMany( 257, std::vector<std::string>{ "PING" } );
    const rw::RedisResult countResult = client.pipeline( tooMany );
    CHECK_FALSE( countResult );
    CHECK( countResult.failure == rw::RedisFailure::Config );

    std::vector<std::vector<std::string>> tooLarge{ { "SET", "key", std::string( 64u * 1024u * 1024u + 4096u, 'x' ) } };
    const rw::RedisResult sizeResult = client.pipeline( tooLarge );
    CHECK_FALSE( sizeResult );
    CHECK( sizeResult.failure == rw::RedisFailure::Config );
}

TEST_CASE( "outbound encoder validates projected size before copying payloads" )
{
    constexpr std::size_t ceiling = 64u * 1024u * 1024u + 4096u;
    constexpr std::size_t oneArgumentFraming = 17;
    const std::string backing( ceiling - oneArgumentFraming + 1, 'x' );
    const std::string_view exact( backing.data(), backing.size() - 1 );
    const std::string_view over( backing );
    std::size_t encodedSize = 0;

    CHECK( rw::RedisClientTestPeer::encodedBatchSize( { { exact } }, encodedSize ) );
    CHECK( encodedSize == ceiling );
    CHECK_FALSE( rw::RedisClientTestPeer::encodedBatchSize( { { over } }, encodedSize ) );
    CHECK_FALSE( rw::RedisClientTestPeer::encodedBatchSize( { { exact }, { "PING" } }, encodedSize ) );

    const std::string hugeViewBacking( 64, 'z' );
    const std::string_view impossible( hugeViewBacking.data(), std::numeric_limits<std::size_t>::max() );
    CHECK_FALSE( rw::RedisClientTestPeer::encodedBatchSize( { { impossible } }, encodedSize ) );
}
