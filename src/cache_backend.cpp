#include "cache_backend.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <optional>
#include <string>
#include <system_error>

namespace rw
{
namespace
{

constexpr std::uint32_t kSha256Initial[] =
{
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
};

constexpr std::uint32_t kSha256Round[] =
{
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

constexpr std::uint32_t rotateRight( const std::uint32_t value, const unsigned bits ) noexcept
{
    return ( value >> bits ) | ( value << ( 32u - bits ) );
}

bool containsControl( const std::string_view value ) noexcept
{
    for( const unsigned char c : value )
    {
        if( c < 0x20u || c == 0x7fu )
        {
            return true;
        }
    }
    return false;
}

std::string environmentValue( const char* name )
{
    const char* value = std::getenv( name );
    return value == nullptr ? std::string() : std::string( value );
}

bool parsePositiveU32( const std::string& value, const char* variable, std::uint32_t& out, std::string& error )
{
    if( value.empty() )
    {
        return true;
    }
    std::uint64_t parsed = 0;
    const auto result = std::from_chars( value.data(), value.data() + value.size(), parsed );
    if( result.ec != std::errc() || result.ptr != value.data() + value.size() || parsed == 0 || parsed > std::numeric_limits<std::uint32_t>::max() )
    {
        error = std::string( "invalid " ) + variable + ": expected a positive base-10 integer";
        return false;
    }
    out = static_cast<std::uint32_t>( parsed );
    return true;
}

bool parseDatabase( const std::string_view value ) noexcept
{
    if( value.empty() )
    {
        return false;
    }
    std::uint32_t database = 0;
    const auto result = std::from_chars( value.data(), value.data() + value.size(), database );
    return result.ec == std::errc() && result.ptr == value.data() + value.size();
}

bool isLoopbackHost( std::string host )
{
    std::ranges::transform( host, host.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
    if( host == "localhost" || host == "[::1]" )
    {
        return true;
    }
    if( !host.starts_with( "127." ) )
    {
        return false;
    }
    unsigned partCount = 0;
    std::size_t begin = 0;
    while( begin <= host.size() )
    {
        const std::size_t end = host.find( '.', begin );
        const std::string_view part( host.data() + begin, ( end == std::string::npos ? host.size() : end ) - begin );
        unsigned value = 0;
        const auto result = std::from_chars( part.data(), part.data() + part.size(), value );
        if( part.empty() || result.ec != std::errc() || result.ptr != part.data() + part.size() || value > 255 )
        {
            return false;
        }
        ++partCount;
        if( end == std::string::npos )
        {
            break;
        }
        begin = end + 1;
    }
    return partCount == 4;
}

bool validateTcpEndpoint( const std::string_view endpoint, const bool allowRemote, std::string& error )
{
    const std::string_view rest = endpoint.substr( 8 );
    const std::size_t slash = rest.find( '/' );
    const std::string_view authority = rest.substr( 0, slash );
    const std::string_view path = slash == std::string_view::npos ? std::string_view() : rest.substr( slash + 1 );
    if( authority.empty() || authority.find( '@' ) != std::string_view::npos )
    {
        error = "invalid RIPWIRE_REDIS_URL: URL userinfo is forbidden; credentials belong in environment variables";
        return false;
    }
    if( path.find( '/' ) != std::string_view::npos || ( !path.empty() && !parseDatabase( path ) ) )
    {
        error = "invalid RIPWIRE_REDIS_URL: TCP path must be an optional numeric database";
        return false;
    }

    std::string_view host = authority;
    std::string_view port;
    if( authority.front() == '[' )
    {
        const std::size_t close = authority.find( ']' );
        if( close == std::string_view::npos || ( close + 1 < authority.size() && authority[close + 1] != ':' ) )
        {
            error = "invalid RIPWIRE_REDIS_URL: malformed bracketed host";
            return false;
        }
        host = authority.substr( 0, close + 1 );
        if( close + 1 < authority.size() )
        {
            port = authority.substr( close + 2 );
        }
    }
    else
    {
        const std::size_t colon = authority.find( ':' );
        if( colon != std::string_view::npos )
        {
            if( authority.find( ':', colon + 1 ) != std::string_view::npos )
            {
                error = "invalid RIPWIRE_REDIS_URL: IPv6 hosts must use brackets";
                return false;
            }
            host = authority.substr( 0, colon );
            port = authority.substr( colon + 1 );
        }
    }
    if( host.empty() )
    {
        error = "invalid RIPWIRE_REDIS_URL: host is required";
        return false;
    }
    if( !port.empty() )
    {
        std::uint32_t portNumber = 0;
        const auto result = std::from_chars( port.data(), port.data() + port.size(), portNumber );
        if( result.ec != std::errc() || result.ptr != port.data() + port.size() || portNumber == 0 || portNumber > 65535 )
        {
            error = "invalid RIPWIRE_REDIS_URL: port must be in 1..65535";
            return false;
        }
    }
    else if( authority.ends_with( ':' ) )
    {
        error = "invalid RIPWIRE_REDIS_URL: port is empty";
        return false;
    }
    if( !allowRemote && !isLoopbackHost( std::string( host ) ) )
    {
        error = "RIPWIRE_REDIS_URL selects plaintext TCP outside loopback; set RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE=1 only for a trusted private transport";
        return false;
    }
    return true;
}

bool validateUnixEndpoint( const std::string_view endpoint, std::string& error )
{
    const std::string_view rest = endpoint.substr( 13 );
    if( rest.empty() || rest.front() != '/' )
    {
        error = "invalid RIPWIRE_REDIS_URL: redis+unix requires an absolute socket path";
        return false;
    }
    const std::size_t query = rest.find( '?' );
    const std::string_view path = rest.substr( 0, query );
    if( path.empty() )
    {
        error = "invalid RIPWIRE_REDIS_URL: Unix socket path is required";
        return false;
    }
    if( query != std::string_view::npos )
    {
        const std::string_view parameter = rest.substr( query + 1 );
        if( !parameter.starts_with( "db=" ) || parameter.find( '&' ) != std::string_view::npos || !parseDatabase( parameter.substr( 3 ) ) )
        {
            error = "invalid RIPWIRE_REDIS_URL: redis+unix accepts only one numeric db query parameter";
            return false;
        }
    }
    return true;
}

bool validateRedisEndpoint( const std::string& endpoint, const bool allowRemote, std::string& error )
{
    if( endpoint.empty() )
    {
        error = "Redis cache requires RIPWIRE_REDIS_URL";
        return false;
    }
    if( endpoint.size() > 4096 || containsControl( endpoint ) || endpoint.find( '#' ) != std::string::npos || endpoint.find( '%' ) != std::string::npos )
    {
        error = "invalid RIPWIRE_REDIS_URL: controls, fragments, and percent escapes are forbidden";
        return false;
    }
    if( endpoint.starts_with( "redis://" ) )
    {
        if( endpoint.find( '?' ) != std::string::npos )
        {
            error = "invalid RIPWIRE_REDIS_URL: TCP endpoints do not accept query parameters";
            return false;
        }
        return validateTcpEndpoint( endpoint, allowRemote, error );
    }
    if( endpoint.starts_with( "redis+unix://" ) )
    {
        return validateUnixEndpoint( endpoint, error );
    }
    error = "invalid RIPWIRE_REDIS_URL: supported schemes are redis:// and redis+unix://";
    return false;
}

bool validIdentityComponent( const std::string_view value ) noexcept
{
    return !value.empty() && value.size() <= 1024 && !containsControl( value ) && value.find( '#' ) == std::string_view::npos
           && value.find( '?' ) == std::string_view::npos && value.find( '%' ) == std::string_view::npos;
}

std::optional<std::filesystem::path> gitDirectoryForRoot( const std::filesystem::path& root, std::filesystem::path& repositoryRoot )
{
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::path cursor = fs::weakly_canonical( root, ec );
    if( ec )
    {
        cursor = fs::absolute( root, ec );
    }
    while( !cursor.empty() )
    {
        const fs::path marker = cursor / ".git";
        if( fs::is_directory( marker, ec ) && !ec )
        {
            repositoryRoot = cursor;
            return marker;
        }
        ec.clear();
        if( fs::is_regular_file( marker, ec ) && !ec )
        {
            std::ifstream input( marker );
            std::string line;
            std::getline( input, line );
            constexpr std::string_view prefix = "gitdir:";
            if( line.starts_with( prefix ) )
            {
                std::string_view target( line );
                target.remove_prefix( prefix.size() );
                while( !target.empty() && ( target.front() == ' ' || target.front() == '\t' ) ) { target.remove_prefix( 1 ); }
                fs::path gitDir( target );
                if( gitDir.is_relative() ) { gitDir = marker.parent_path() / gitDir; }
                gitDir = fs::weakly_canonical( gitDir, ec );
                if( !ec )
                {
                    repositoryRoot = cursor;
                    return gitDir;
                }
            }
            return std::nullopt;
        }
        ec.clear();
        const fs::path parent = cursor.parent_path();
        if( parent == cursor )
        {
            break;
        }
        cursor = parent;
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> gitConfigPath( const std::filesystem::path& gitDir )
{
    namespace fs = std::filesystem;
    std::error_code ec;
    if( fs::is_regular_file( gitDir / "config", ec ) && !ec )
    {
        return gitDir / "config";
    }
    std::ifstream commonInput( gitDir / "commondir" );
    std::string common;
    std::getline( commonInput, common );
    if( common.empty() || containsControl( common ) )
    {
        return std::nullopt;
    }
    fs::path commonDir( common );
    if( commonDir.is_relative() ) { commonDir = gitDir / commonDir; }
    commonDir = fs::weakly_canonical( commonDir, ec );
    if( ec || !fs::is_regular_file( commonDir / "config", ec ) || ec )
    {
        return std::nullopt;
    }
    return commonDir / "config";
}

std::optional<std::string> originRemote( const std::filesystem::path& configPath )
{
    std::ifstream input( configPath );
    std::string line;
    bool inOrigin = false;
    while( std::getline( input, line ) )
    {
        std::string_view view( line );
        while( !view.empty() && ( view.front() == ' ' || view.front() == '\t' ) ) { view.remove_prefix( 1 ); }
        while( !view.empty() && ( view.back() == ' ' || view.back() == '\t' || view.back() == '\r' ) ) { view.remove_suffix( 1 ); }
        if( view.starts_with( '[' ) )
        {
            std::string section( view );
            std::ranges::transform( section, section.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
            inOrigin = section == "[remote \"origin\"]";
            continue;
        }
        if( !inOrigin )
        {
            continue;
        }
        const std::size_t equals = view.find( '=' );
        if( equals == std::string_view::npos )
        {
            continue;
        }
        std::string_view key = view.substr( 0, equals );
        std::string_view value = view.substr( equals + 1 );
        while( !key.empty() && ( key.back() == ' ' || key.back() == '\t' ) ) { key.remove_suffix( 1 ); }
        while( !value.empty() && ( value.front() == ' ' || value.front() == '\t' ) ) { value.remove_prefix( 1 ); }
        std::string normalizedKey( key );
        std::ranges::transform( normalizedKey, normalizedKey.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        if( normalizedKey == "url" )
        {
            return std::string( value );
        }
    }
    return std::nullopt;
}

std::optional<std::string> normalizeGitRemote( const std::string_view remote, std::string& error )
{
    if( remote.empty() || remote.size() > 4096 || containsControl( remote ) || remote.find( '#' ) != std::string_view::npos
        || remote.find( '?' ) != std::string_view::npos || remote.find( '%' ) != std::string_view::npos || remote.find( '\\' ) != std::string_view::npos )
    {
        error = "Git remote cannot be normalized for Redis project identity";
        return std::nullopt;
    }

    std::string host;
    std::string port;
    std::string path;
    std::string lower( remote );
    std::ranges::transform( lower, lower.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
    if( lower.starts_with( "https://" ) || lower.starts_with( "ssh://" ) )
    {
        const bool ssh = lower.starts_with( "ssh://" );
        std::string_view rest = remote.substr( ssh ? 6 : 8 );
        const std::size_t slash = rest.find( '/' );
        if( slash == std::string_view::npos )
        {
            error = "Git remote cannot be normalized for Redis project identity";
            return std::nullopt;
        }
        std::string_view authority = rest.substr( 0, slash );
        path = std::string( rest.substr( slash + 1 ) );
        const std::size_t at = authority.find( '@' );
        if( at != std::string_view::npos )
        {
            std::string user( authority.substr( 0, at ) );
            std::ranges::transform( user, user.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
            if( !ssh || user != "git" || authority.find( '@', at + 1 ) != std::string_view::npos )
            {
                error = "Git remote userinfo is not supported for Redis project identity";
                return std::nullopt;
            }
            authority.remove_prefix( at + 1 );
        }
        const std::size_t colon = authority.rfind( ':' );
        if( colon != std::string_view::npos && authority.find( ':' ) == colon )
        {
            host = std::string( authority.substr( 0, colon ) );
            std::ranges::transform( host, host.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
            port = std::string( authority.substr( colon + 1 ) );
            const std::string defaultPort = ssh ? "22" : "443";
            if( port == defaultPort ) { port.clear(); }
            if( !port.empty() && !parseDatabase( port ) )
            {
                error = "Git remote port is invalid for Redis project identity";
                return std::nullopt;
            }
        }
        else
        {
            host = std::string( authority );
            std::ranges::transform( host, host.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        }
    }
    else
    {
        constexpr std::string_view prefix = "git@";
        if( !lower.starts_with( prefix ) )
        {
            error = "Git remote transport is unsupported for Redis project identity";
            return std::nullopt;
        }
        const std::string_view rest = remote.substr( prefix.size() );
        const std::size_t colon = rest.find( ':' );
        if( colon == std::string_view::npos )
        {
            error = "Git remote cannot be normalized for Redis project identity";
            return std::nullopt;
        }
        host = std::string( rest.substr( 0, colon ) );
        std::ranges::transform( host, host.begin(), []( const unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        path = std::string( rest.substr( colon + 1 ) );
    }
    while( !path.empty() && path.front() == '/' ) { path.erase( path.begin() ); }
    while( !path.empty() && path.back() == '/' ) { path.pop_back(); }
    if( path.ends_with( ".git" ) ) { path.resize( path.size() - 4 ); }
    if( host.empty() || path.empty() || path.starts_with( "." ) || path.find( "/../" ) != std::string::npos )
    {
        error = "Git remote cannot be normalized for Redis project identity";
        return std::nullopt;
    }
    return host + ( port.empty() ? std::string() : ":" + port ) + "/" + path;
}

}

std::string redisKeyHash( const std::string_view value )
{
    std::array<std::uint32_t, 8> state{};
    for( std::size_t i = 0; i < state.size(); ++i ) { state[i] = kSha256Initial[i]; }
    const std::uint64_t bitLength = static_cast<std::uint64_t>( value.size() ) * 8u;
    const std::size_t paddedSize = ( ( value.size() + 9u + 63u ) / 64u ) * 64u;

    for( std::size_t offset = 0; offset < paddedSize; offset += 64 )
    {
        std::array<std::uint32_t, 64> words{};
        for( std::size_t i = 0; i < 64; ++i )
        {
            std::uint8_t byte = 0;
            const std::size_t index = offset + i;
            if( index < value.size() ) { byte = static_cast<std::uint8_t>( value[index] ); }
            else if( index == value.size() ) { byte = 0x80u; }
            else if( index >= paddedSize - 8u ) { byte = static_cast<std::uint8_t>( bitLength >> ( ( paddedSize - 1u - index ) * 8u ) ); }
            words[i / 4] |= static_cast<std::uint32_t>( byte ) << ( 24u - static_cast<unsigned>( i % 4u ) * 8u );
        }
        for( std::size_t i = 16; i < words.size(); ++i )
        {
            const std::uint32_t s0 = rotateRight( words[i - 15], 7 ) ^ rotateRight( words[i - 15], 18 ) ^ ( words[i - 15] >> 3 );
            const std::uint32_t s1 = rotateRight( words[i - 2], 17 ) ^ rotateRight( words[i - 2], 19 ) ^ ( words[i - 2] >> 10 );
            words[i] = words[i - 16] + s0 + words[i - 7] + s1;
        }
        std::uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
        std::uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
        for( std::size_t i = 0; i < words.size(); ++i )
        {
            const std::uint32_t sum1 = rotateRight( e, 6 ) ^ rotateRight( e, 11 ) ^ rotateRight( e, 25 );
            const std::uint32_t choice = ( e & f ) ^ ( ~e & g );
            const std::uint32_t temporary1 = h + sum1 + choice + kSha256Round[i] + words[i];
            const std::uint32_t sum0 = rotateRight( a, 2 ) ^ rotateRight( a, 13 ) ^ rotateRight( a, 22 );
            const std::uint32_t majority = ( a & b ) ^ ( a & c ) ^ ( b & c );
            const std::uint32_t temporary2 = sum0 + majority;
            h = g; g = f; f = e; e = d + temporary1; d = c; c = b; b = a; a = temporary1 + temporary2;
        }
        state[0] += a; state[1] += b; state[2] += c; state[3] += d;
        state[4] += e; state[5] += f; state[6] += g; state[7] += h;
    }

    constexpr char hex[] = "0123456789abcdef";
    std::string output( 64, '0' );
    for( std::size_t i = 0; i < state.size(); ++i )
    {
        for( std::size_t nibble = 0; nibble < 8; ++nibble )
        {
            output[i * 8 + nibble] = hex[( state[i] >> ( 28u - static_cast<unsigned>( nibble ) * 4u ) ) & 0x0fu];
        }
    }
    return output;
}

bool resolveCachePolicy( const CacheSelectionInput& input, std::shared_ptr<const CachePolicy>& out, std::string& error )
{
    error.clear();
    auto policy = std::make_shared<CachePolicy>();
    if( input.noCache )
    {
        policy->kind = CacheBackendKind::Disabled;
        out = std::move( policy );
        return true;
    }
    if( input.cacheWasExplicit && input.explicitCache != "redis" )
    {
        policy->kind = CacheBackendKind::File;
        policy->explicitFilePath = std::string( input.explicitCache );
        out = std::move( policy );
        return true;
    }
    const bool explicitRedis = input.cacheWasExplicit && input.explicitCache == "redis";
    if( !explicitRedis && input.environmentBackend.empty() )
    {
        policy->kind = CacheBackendKind::File;
        out = std::move( policy );
        return true;
    }
    if( !explicitRedis && input.environmentBackend != "redis" )
    {
        error = "invalid RIPWIRE_CACHE_BACKEND: supported value is redis";
        return false;
    }

    policy->kind = CacheBackendKind::Redis;
    policy->redis.endpoint = environmentValue( "RIPWIRE_REDIS_URL" );
    policy->redis.username = environmentValue( "RIPWIRE_REDIS_USERNAME" );
    policy->redis.password = environmentValue( "RIPWIRE_REDIS_PASSWORD" );
    policy->redis.nameSpace = environmentValue( "RIPWIRE_REDIS_NAMESPACE" );
    policy->redis.project = environmentValue( "RIPWIRE_REDIS_PROJECT" );
    const std::string allowRemote = environmentValue( "RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE" );
    if( allowRemote == "1" ) { policy->redis.allowPlaintextRemote = true; }
    else if( !allowRemote.empty() && allowRemote != "0" )
    {
        error = "invalid RIPWIRE_REDIS_ALLOW_PLAINTEXT_REMOTE: expected 0 or 1";
        return false;
    }
    if( !validateRedisEndpoint( policy->redis.endpoint, policy->redis.allowPlaintextRemote, error ) )
    {
        return false;
    }
    if( !validIdentityComponent( policy->redis.nameSpace ) )
    {
        error = "Redis cache requires a valid RIPWIRE_REDIS_NAMESPACE";
        return false;
    }
    if( !policy->redis.project.empty() && !validIdentityComponent( policy->redis.project ) )
    {
        error = "invalid RIPWIRE_REDIS_PROJECT";
        return false;
    }
    if( containsControl( policy->redis.username ) || containsControl( policy->redis.password ) )
    {
        error = "Redis credentials may not contain control characters";
        return false;
    }

    std::uint32_t ttlDays = 30;
    if( !parsePositiveU32( environmentValue( "RIPWIRE_REDIS_TTL_DAYS" ), "RIPWIRE_REDIS_TTL_DAYS", ttlDays, error )
        || ttlDays > std::numeric_limits<std::uint32_t>::max() / ( 24u * 60u * 60u ) )
    {
        if( error.empty() ) { error = "invalid RIPWIRE_REDIS_TTL_DAYS: value overflows seconds"; }
        return false;
    }
    policy->redis.ttlSeconds = ttlDays * 24u * 60u * 60u;
    if( !parsePositiveU32( environmentValue( "RIPWIRE_REDIS_TIMEOUT_MS" ), "RIPWIRE_REDIS_TIMEOUT_MS", policy->redis.timeoutMs, error ) )
    {
        return false;
    }
    out = std::move( policy );
    return true;
}

std::string redisProjectIdentity( const std::string_view root, const std::string_view overrideValue, std::string& error )
{
    error.clear();
    if( !overrideValue.empty() )
    {
        if( !validIdentityComponent( overrideValue ) )
        {
            error = "invalid RIPWIRE_REDIS_PROJECT";
            return {};
        }
        return std::string( overrideValue );
    }

    namespace fs = std::filesystem;
    fs::path repositoryRoot;
    const std::optional<fs::path> gitDir = gitDirectoryForRoot( fs::path( root ), repositoryRoot );
    if( !gitDir )
    {
        error = "Redis cache needs RIPWIRE_REDIS_PROJECT for a non-Git root";
        return {};
    }
    const std::optional<fs::path> configPath = gitConfigPath( *gitDir );
    const std::optional<std::string> remote = configPath ? originRemote( *configPath ) : std::nullopt;
    if( !remote )
    {
        error = "Redis cache needs RIPWIRE_REDIS_PROJECT when Git origin is unavailable";
        return {};
    }
    const std::optional<std::string> normalized = normalizeGitRemote( *remote, error );
    if( !normalized )
    {
        return {};
    }
    std::error_code ec;
    fs::path absoluteRoot = fs::weakly_canonical( fs::path( root ), ec );
    if( ec )
    {
        error = "Redis cache could not normalize the crawl root";
        return {};
    }
    fs::path relative = absoluteRoot.lexically_relative( repositoryRoot );
    if( relative.empty() ) { relative = "."; }
    if( relative.is_absolute() || ( !relative.empty() && *relative.begin() == ".." ) )
    {
        error = "Redis cache crawl root is outside its Git repository";
        return {};
    }
    return *normalized + "\n" + relative.generic_string();
}

bool cacheContextForRoot( std::shared_ptr<const CachePolicy> policy, const std::string_view root,
                          const bool captureValueUses, CacheContext& out, std::string& error )
{
    error.clear();
    if( !policy )
    {
        error = "cache policy is missing";
        return false;
    }
    CacheContext context;
    context.policy = std::move( policy );
    context.captureValueUses = captureValueUses;
    if( context.policy->kind == CacheBackendKind::File )
    {
        context.filePath = context.policy->explicitFilePath;
    }
    else if( context.policy->kind == CacheBackendKind::Redis )
    {
        context.project = redisProjectIdentity( root, context.policy->redis.project, error );
        if( context.project.empty() )
        {
            return false;
        }
    }
    out = std::move( context );
    return true;
}

}
