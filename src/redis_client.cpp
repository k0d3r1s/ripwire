#include "redis_client.h"
#include "infra/emit.h"
#include "infra/Diagnostics.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <limits>
#include <limits.h>
#include <poll.h>
#include <spawn.h>
#include <signal.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <vector>

#if defined( __APPLE__ )
#include <mach-o/dyld.h>
#endif

extern char** environ;

namespace rw
{

std::atomic<bool> redisCacheWarningIssued{ false };
std::atomic<unsigned> redisCacheFailureClasses{ 0 };

void redisIngestDegraded( RedisFailure failure )
{
    redisCacheFailureClasses.fetch_or( 1u << static_cast<unsigned>( failure ), std::memory_order_relaxed );
    if( !redisCacheWarningIssued.exchange( true, std::memory_order_relaxed ) )
    {
#if !defined( NDEBUG )
        DEGRADED_PATH_ALERT( "Redis cache unavailable or invalid — affected files use source; no local cache fallback" );
#else
        emitTo( stderr, "ripwire: Redis cache unavailable or invalid — affected files use source; no local cache fallback\n" );
#endif
    }
}

namespace
{

constexpr std::size_t kMaximumBulkBytes = 64u * 1024u * 1024u;
constexpr std::size_t kMaximumArrayElements = 4096;
constexpr std::size_t kMaximumReplyNodes = 16384;
constexpr std::size_t kMaximumReplyDepth = 4;
constexpr std::size_t kMaximumAggregateBytes = 128u * 1024u * 1024u;
constexpr std::size_t kMaximumPipelineCommands = 256;
constexpr std::size_t kMaximumRequestBytes = 64u * 1024u * 1024u + 4096u;
constexpr std::size_t kMaximumResolvedAddresses = 16;
constexpr std::size_t kMaximumResolverHostBytes = 4096;

enum class EndpointKind : std::uint8_t { Tcp, Unix };
enum class ParseStatus : std::uint8_t { Complete, NeedMore, Invalid };
enum class InterruptibleCall : std::uint8_t { PipeRequest, PipeResponse, Fcntl, Connect, GetSockOpt, GetPeerName, Stat, Lstat, UnixPeer, Count };

struct Endpoint
{
    EndpointKind kind = EndpointKind::Tcp;
    std::string host;
    std::string port = "6379";
    std::string path;
    std::uint32_t database = 0;
};

struct ParseContext
{
    std::string_view input;
    std::size_t position = 0;
    std::size_t nodeCount = 0;
    std::size_t aggregateBytes = 0;
    std::size_t aggregateLimit = kMaximumAggregateBytes;
};

struct ParseOutcome
{
    ParseStatus status = ParseStatus::Invalid;
    std::vector<RedisReply> replies;
};

struct ResolvedAddress
{
    int family = AF_UNSPEC;
    int socketType = SOCK_STREAM;
    int protocol = IPPROTO_TCP;
    socklen_t length = 0;
    sockaddr_storage address{};
};

struct ResolverPacket
{
    std::int32_t status = -1;
    std::uint32_t addressCount = 0;
    std::array<ResolvedAddress, kMaximumResolvedAddresses> addresses{};
};

struct ResolverRequest
{
    std::uint32_t hostLength = 0;
    std::uint32_t portLength = 0;
    std::uint32_t delayMilliseconds = 0;
    std::uint32_t overrideCount = 0;
    std::array<char, kMaximumResolverHostBytes + 1> host{};
    std::array<char, 6> port{};
    std::array<std::array<char, INET6_ADDRSTRLEN>, kMaximumResolvedAddresses> overrideAddresses{};
};

#if defined( RIPWIRE_REDIS_TESTING )
struct RedisTestHooks
{
    std::array<unsigned, static_cast<std::size_t>( InterruptibleCall::Count )> eintr{};
    std::uint32_t resolverDelayMs = 0;
    std::vector<std::string> resolverAddresses;
    bool peerMismatch = false;
    bool unixPathSwap = false;
    bool unsafeUnixOwner = false;
    bool noSigPipeFailure = false;
};

RedisTestHooks redisTestHooks;
#endif

class SocketHandle
{
  public:
    SocketHandle() = default;
    explicit SocketHandle( const int value ) : value_( value ) {}
    ~SocketHandle()
    {
        if( value_ >= 0 )
        {
            close( value_ );
        }
    }
    SocketHandle( const SocketHandle& ) = delete;
    SocketHandle& operator=( const SocketHandle& ) = delete;
    SocketHandle( SocketHandle&& other ) noexcept : value_( other.value_ ) { other.value_ = -1; }
    SocketHandle& operator=( SocketHandle&& ) = delete;
    [[nodiscard]] int get() const noexcept { return value_; }
    [[nodiscard]] explicit operator bool() const noexcept { return value_ >= 0; }
    void reset() noexcept
    {
        if( value_ >= 0 )
        {
            close( value_ );
            value_ = -1;
        }
    }

  private:
    int value_ = -1;
};

using Deadline = std::chrono::steady_clock::time_point;

const char* failureName( const RedisFailure failure ) noexcept
{
    constexpr std::array<const char*, 8> names{ "none", "config", "connect", "timeout", "protocol", "auth", "cluster redirect", "server" };
    const std::size_t index = static_cast<std::size_t>( failure );
    return index < names.size() ? names[index] : "server";
}

std::string endpointName( const EndpointKind kind )
{
    return kind == EndpointKind::Unix ? "unix" : "tcp";
}

RedisResult failureResult( const RedisFailure failure, const std::string_view endpointClass, const std::string_view category = {} )
{
    RedisResult result;
    result.failure = failure;
    result.diagnostic = "redis " + std::string( endpointClass ) + ": " + failureName( failure );
    if( !category.empty() )
    {
        result.diagnostic += " ";
        result.diagnostic += category;
    }
    return result;
}

bool containsForbiddenUrlByte( const std::string_view value ) noexcept
{
    return std::any_of( value.begin(), value.end(), []( const unsigned char byte ) { return byte <= 0x20 || byte == 0x7f; } );
}

bool parseDecimalMagnitude( const std::string_view digits, const std::uint64_t maximum, std::uint64_t& output ) noexcept
{
    if( digits.empty() )
    {
        return false;
    }
    std::uint64_t value = 0;
    for( const unsigned char digit : digits )
    {
        if( digit < '0' || digit > '9' )
        {
            return false;
        }
        const std::uint64_t numeric = digit - '0';
        if( value > ( maximum - numeric ) / 10 )
        {
            return false;
        }
        value = value * 10 + numeric;
    }
    output = value;
    return true;
}

bool parseUnsigned( const std::string_view value, std::uint32_t& output, const std::uint32_t maximum ) noexcept
{
    std::uint64_t parsed = 0;
    if( !parseDecimalMagnitude( value, maximum, parsed ) )
    {
        return false;
    }
    output = static_cast<std::uint32_t>( parsed );
    return true;
}

bool parseEndpoint( const std::string_view value, Endpoint& output )
{
    if( value.empty() || value.size() > 4096 || containsForbiddenUrlByte( value ) || value.find( '%' ) != std::string_view::npos
        || value.find( '#' ) != std::string_view::npos || value.find( '@' ) != std::string_view::npos )
    {
        return false;
    }
    Endpoint parsed;
    if( value.starts_with( "redis://" ) )
    {
        const std::string_view remainder = value.substr( 8 );
        if( remainder.empty() || remainder.find( '?' ) != std::string_view::npos )
        {
            return false;
        }
        const std::size_t slash = remainder.find( '/' );
        const std::string_view authority = remainder.substr( 0, slash );
        const std::string_view database = slash == std::string_view::npos ? std::string_view() : remainder.substr( slash + 1 );
        if( authority.empty() || ( slash != std::string_view::npos && ( database.empty() || database.find( '/' ) != std::string_view::npos ) ) )
        {
            return false;
        }
        std::string_view host;
        std::string_view port;
        if( authority.front() == '[' )
        {
            const std::size_t close = authority.find( ']' );
            if( close == std::string_view::npos || close == 1 || authority.find( '[', 1 ) != std::string_view::npos
                || authority.find( ']', close + 1 ) != std::string_view::npos )
            {
                return false;
            }
            host = authority.substr( 1, close - 1 );
            in6_addr address{};
            if( inet_pton( AF_INET6, std::string( host ).c_str(), &address ) != 1 )
            {
                return false;
            }
            const std::string_view suffix = authority.substr( close + 1 );
            if( !suffix.empty() )
            {
                if( suffix.front() != ':' || suffix.size() == 1 )
                {
                    return false;
                }
                port = suffix.substr( 1 );
            }
        }
        else
        {
            if( authority.find( '[' ) != std::string_view::npos || authority.find( ']' ) != std::string_view::npos )
            {
                return false;
            }
            const std::size_t colon = authority.find( ':' );
            if( colon == std::string_view::npos )
            {
                host = authority;
            }
            else
            {
                if( authority.find( ':', colon + 1 ) != std::string_view::npos || colon == 0 || colon + 1 == authority.size() )
                {
                    return false;
                }
                host = authority.substr( 0, colon );
                port = authority.substr( colon + 1 );
            }
        }
        if( host.empty() || host.find_first_of( "/\\" ) != std::string_view::npos )
        {
            return false;
        }
        std::uint32_t portNumber = 6379;
        if( !port.empty() && ( !parseUnsigned( port, portNumber, 65535 ) || portNumber == 0 ) )
        {
            return false;
        }
        if( !database.empty() && !parseUnsigned( database, parsed.database, std::numeric_limits<std::int32_t>::max() ) )
        {
            return false;
        }
        parsed.kind = EndpointKind::Tcp;
        parsed.host = host;
        parsed.port = std::to_string( portNumber );
    }
    else if( value.starts_with( "redis+unix://" ) )
    {
        const std::string_view remainder = value.substr( 13 );
        if( remainder.empty() || remainder.front() != '/' )
        {
            return false;
        }
        const std::size_t query = remainder.find( '?' );
        const std::string_view path = remainder.substr( 0, query );
        if( path.empty() || path.find( "//" ) != std::string_view::npos || path.ends_with( "/" ) )
        {
            return false;
        }
        std::size_t segmentStart = 1;
        while( segmentStart < path.size() )
        {
            const std::size_t segmentEnd = path.find( '/', segmentStart );
            const std::string_view segment = path.substr( segmentStart, segmentEnd - segmentStart );
            if( segment == "." || segment == ".." )
            {
                return false;
            }
            if( segmentEnd == std::string_view::npos )
            {
                break;
            }
            segmentStart = segmentEnd + 1;
        }
        if( query != std::string_view::npos )
        {
            const std::string_view parameter = remainder.substr( query + 1 );
            if( !parameter.starts_with( "db=" ) || parameter.find( '&' ) != std::string_view::npos
                || !parseUnsigned( parameter.substr( 3 ), parsed.database, std::numeric_limits<std::int32_t>::max() ) )
            {
                return false;
            }
        }
        parsed.kind = EndpointKind::Unix;
        parsed.path = path;
    }
    else
    {
        return false;
    }
    output = std::move( parsed );
    return true;
}

bool isLoopbackAddress( const sockaddr* address ) noexcept
{
    if( address->sa_family == AF_INET )
    {
        const auto* ipv4 = reinterpret_cast<const sockaddr_in*>( address );
        return ( ntohl( ipv4->sin_addr.s_addr ) & 0xff000000u ) == 0x7f000000u;
    }
    if( address->sa_family == AF_INET6 )
    {
        const auto* ipv6 = reinterpret_cast<const sockaddr_in6*>( address );
        if( IN6_IS_ADDR_LOOPBACK( &ipv6->sin6_addr ) )
        {
            return true;
        }
        if( IN6_IS_ADDR_V4MAPPED( &ipv6->sin6_addr ) )
        {
            std::uint32_t ipv4 = 0;
            std::memcpy( &ipv4, &ipv6->sin6_addr.s6_addr[12], sizeof( ipv4 ) );
            return ( ntohl( ipv4 ) & 0xff000000u ) == 0x7f000000u;
        }
    }
    return false;
}

bool injectInterruption( const InterruptibleCall call ) noexcept
{
#if defined( RIPWIRE_REDIS_TESTING )
    unsigned& remaining = redisTestHooks.eintr[static_cast<std::size_t>( call )];
    if( remaining > 0 )
    {
        --remaining;
        errno = EINTR;
        return true;
    }
#else
    (void)call;
#endif
    return false;
}

int remainingMilliseconds( Deadline deadline ) noexcept;

int retryFcntl( const int descriptor, const int command, const int argument, const Deadline deadline ) noexcept
{
    while( remainingMilliseconds( deadline ) > 0 )
    {
        const int result = injectInterruption( InterruptibleCall::Fcntl ) ? -1 : fcntl( descriptor, command, argument );
        if( result >= 0 || errno != EINTR )
        {
            return result;
        }
    }
    errno = ETIMEDOUT;
    return -1;
}

RedisFailure retryPipe( int descriptors[2], const InterruptibleCall call, const Deadline deadline ) noexcept
{
    int result = -1;
    do
    {
        if( remainingMilliseconds( deadline ) == 0 )
        {
            errno = ETIMEDOUT;
            return RedisFailure::Timeout;
        }
        result = injectInterruption( call ) ? -1 : pipe( descriptors );
    } while( result != 0 && errno == EINTR );
    return result == 0 ? RedisFailure::None : RedisFailure::Connect;
}

bool setDescriptorFlags( const int descriptor, const Deadline deadline ) noexcept
{
    const int descriptorFlags = retryFcntl( descriptor, F_GETFD, 0, deadline );
    const int statusFlags = retryFcntl( descriptor, F_GETFL, 0, deadline );
    return descriptorFlags >= 0 && statusFlags >= 0 && retryFcntl( descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC, deadline ) == 0
           && retryFcntl( descriptor, F_SETFL, statusFlags | O_NONBLOCK, deadline ) == 0;
}

bool setResolverChildDescriptorFlag( const int descriptor, const int target, const Deadline deadline ) noexcept
{
    const int flags = retryFcntl( descriptor, F_GETFD, 0, deadline );
    if( flags < 0 )
    {
        return false;
    }
    const int childFlags = descriptor == target ? flags & ~FD_CLOEXEC : flags | FD_CLOEXEC;
    return retryFcntl( descriptor, F_SETFD, childFlags, deadline ) == 0;
}

int remainingMilliseconds( const Deadline deadline ) noexcept
{
    const auto remaining = deadline - std::chrono::steady_clock::now();
    if( remaining <= Deadline::duration::zero() )
    {
        return 0;
    }
    const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>( remaining );
    if( milliseconds.count() >= std::numeric_limits<int>::max() )
    {
        return std::numeric_limits<int>::max();
    }
    return static_cast<int>( milliseconds.count() + ( milliseconds < remaining ? 1 : 0 ) );
}

RedisFailure configureNoSigPipe( const int descriptor, const Deadline deadline ) noexcept
{
#if defined( RIPWIRE_REDIS_TESTING )
    if( redisTestHooks.noSigPipeFailure )
    {
        redisTestHooks.noSigPipeFailure = false;
        return RedisFailure::Connect;
    }
#endif
#if defined( SO_NOSIGPIPE )
    const int enabled = 1;
    while( remainingMilliseconds( deadline ) > 0 )
    {
        if( setsockopt( descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof( enabled ) ) == 0 )
        {
            return RedisFailure::None;
        }
        if( errno != EINTR )
        {
            return RedisFailure::Connect;
        }
    }
    return RedisFailure::Timeout;
#else
    (void)descriptor;
    (void)deadline;
    return RedisFailure::None;
#endif
}

bool waitForSocket( const int descriptor, const short events, const Deadline deadline, bool& timedOut ) noexcept
{
    timedOut = false;
    while( true )
    {
        const int remaining = remainingMilliseconds( deadline );
        if( remaining == 0 )
        {
            timedOut = true;
            return false;
        }
        pollfd request{ descriptor, events, 0 };
        const int result = poll( &request, 1, remaining );
        if( result > 0 )
        {
            return true;
        }
        if( result == 0 )
        {
            timedOut = true;
            return false;
        }
        if( errno != EINTR )
        {
            return false;
        }
    }
}

int retryConnect( const int descriptor, const sockaddr* address, const socklen_t addressLength, const Deadline deadline ) noexcept
{
    while( remainingMilliseconds( deadline ) > 0 )
    {
        const int result = injectInterruption( InterruptibleCall::Connect ) ? -1 : connect( descriptor, address, addressLength );
        if( result == 0 || errno != EINTR )
        {
            return result;
        }
    }
    errno = ETIMEDOUT;
    return -1;
}

int retryGetSockOpt( const int descriptor, const int level, const int option, void* value, socklen_t* length, const Deadline deadline ) noexcept
{
    while( remainingMilliseconds( deadline ) > 0 )
    {
        const int result = injectInterruption( InterruptibleCall::GetSockOpt ) ? -1 : getsockopt( descriptor, level, option, value, length );
        if( result == 0 || errno != EINTR )
        {
            return result;
        }
    }
    errno = ETIMEDOUT;
    return -1;
}

int retryGetPeerName( const int descriptor, sockaddr* address, socklen_t* length, const Deadline deadline ) noexcept
{
    while( remainingMilliseconds( deadline ) > 0 )
    {
        const int result = injectInterruption( InterruptibleCall::GetPeerName ) ? -1 : getpeername( descriptor, address, length );
        if( result == 0 || errno != EINTR )
        {
            return result;
        }
    }
    errno = ETIMEDOUT;
    return -1;
}

bool reapResolver( const pid_t processId, const bool terminate, const Deadline deadline ) noexcept
{
    if( terminate )
    {
        while( kill( processId, SIGKILL ) != 0 && errno == EINTR ) {}
        while( waitpid( processId, nullptr, 0 ) < 0 && errno == EINTR ) {}
        return false;
    }
    while( true )
    {
        const pid_t result = waitpid( processId, nullptr, WNOHANG );
        if( result == processId || ( result < 0 && errno == ECHILD ) )
        {
            return true;
        }
        if( result < 0 && errno != EINTR )
        {
            return false;
        }
        const int remaining = remainingMilliseconds( deadline );
        if( remaining == 0 )
        {
            return reapResolver( processId, true, deadline );
        }
        while( poll( nullptr, 0, std::min( remaining, 1 ) ) < 0 && errno == EINTR ) {}
    }
}

bool appendNumericAddress( const std::string_view text, const std::uint16_t port, ResolverPacket& packet ) noexcept
{
    if( packet.addressCount >= packet.addresses.size() )
    {
        return false;
    }
    ResolvedAddress& output = packet.addresses[packet.addressCount];
    sockaddr_in ipv4{};
    sockaddr_in6 ipv6{};
    const std::string terminated( text );
    if( inet_pton( AF_INET, terminated.c_str(), &ipv4.sin_addr ) == 1 )
    {
        ipv4.sin_family = AF_INET;
        ipv4.sin_port = htons( port );
        output.family = AF_INET;
        output.length = sizeof( ipv4 );
        std::memcpy( &output.address, &ipv4, sizeof( ipv4 ) );
    }
    else if( inet_pton( AF_INET6, terminated.c_str(), &ipv6.sin6_addr ) == 1 )
    {
        ipv6.sin6_family = AF_INET6;
        ipv6.sin6_port = htons( port );
        output.family = AF_INET6;
        output.length = sizeof( ipv6 );
        std::memcpy( &output.address, &ipv6, sizeof( ipv6 ) );
    }
    else
    {
        return false;
    }
    ++packet.addressCount;
    return true;
}

bool readFixedPacket( const int descriptor, void* destination, const std::size_t size ) noexcept
{
    char* bytes = static_cast<char*>( destination );
    std::size_t received = 0;
    while( received < size )
    {
        const ssize_t result = read( descriptor, bytes + received, size - received );
        if( result > 0 )
        {
            received += static_cast<std::size_t>( result );
            continue;
        }
        if( result < 0 && errno == EINTR )
        {
            continue;
        }
        return false;
    }
    return true;
}

bool writeFixedPacket( const int descriptor, const void* source, const std::size_t size ) noexcept
{
    const char* bytes = static_cast<const char*>( source );
    std::size_t written = 0;
    while( written < size )
    {
        const ssize_t result = write( descriptor, bytes + written, size - written );
        if( result > 0 )
        {
            written += static_cast<std::size_t>( result );
            continue;
        }
        if( result < 0 && errno == EINTR )
        {
            continue;
        }
        return false;
    }
    return true;
}

template<std::size_t Size>
bool exactFixedString( const std::array<char, Size>& bytes, const std::uint32_t length, std::string_view& value ) noexcept
{
    if( length == 0 || length >= Size || bytes[length] != '\0' || std::memchr( bytes.data(), '\0', length ) != nullptr )
    {
        return false;
    }
    value = std::string_view( bytes.data(), length );
    return true;
}

template<std::size_t Size>
bool boundedFixedString( const std::array<char, Size>& bytes, std::string_view& value ) noexcept
{
    const void* terminator = std::memchr( bytes.data(), '\0', Size );
    if( terminator == nullptr || terminator == bytes.data() )
    {
        return false;
    }
    value = std::string_view( bytes.data(), static_cast<const char*>( terminator ) - bytes.data() );
    return true;
}

bool validateResolverRequest( const ResolverRequest& request ) noexcept
{
    std::string_view host;
    std::string_view port;
    if( request.overrideCount > request.overrideAddresses.size() || !exactFixedString( request.host, request.hostLength, host )
        || !exactFixedString( request.port, request.portLength, port ) )
    {
        return false;
    }
    for( std::size_t addressIndex = 0; addressIndex < request.overrideCount; ++addressIndex )
    {
        std::string_view address;
        if( !boundedFixedString( request.overrideAddresses[addressIndex], address ) )
        {
            return false;
        }
    }
    return true;
}

void resolveOverrideAddresses( const ResolverRequest& request, ResolverPacket& packet ) noexcept
{
    std::uint32_t port = 0;
    packet.status = parseUnsigned( std::string_view( request.port.data(), request.portLength ), port, 65535 ) ? 0 : -1;
    for( std::size_t addressIndex = 0; addressIndex < request.overrideCount && packet.status == 0; ++addressIndex )
    {
        std::string_view address;
        if( !boundedFixedString( request.overrideAddresses[addressIndex], address )
            || !appendNumericAddress( address, static_cast<std::uint16_t>( port ), packet ) )
        {
            packet.status = -1;
            packet.addressCount = 0;
        }
    }
}

void resolveRequest( const ResolverRequest& request, ResolverPacket& packet ) noexcept
{
    if( request.delayMilliseconds > 0 )
    {
        timespec remaining{ static_cast<time_t>( request.delayMilliseconds / 1000u ), static_cast<long>( request.delayMilliseconds % 1000u ) * 1000000L };
        while( nanosleep( &remaining, &remaining ) != 0 && errno == EINTR ) {}
    }
    if( request.overrideCount > 0 )
    {
        resolveOverrideAddresses( request, packet );
        return;
    }
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo* addresses = nullptr;
    packet.status = getaddrinfo( request.host.data(), request.port.data(), &hints, &addresses ) == 0 ? 0 : -1;
    if( packet.status == 0 )
    {
        for( const addrinfo* candidate = addresses; candidate; candidate = candidate->ai_next )
        {
            if( packet.addressCount >= packet.addresses.size() || candidate->ai_addrlen > sizeof( sockaddr_storage ) )
            {
                packet.status = -1;
                packet.addressCount = 0;
                break;
            }
            ResolvedAddress& output = packet.addresses[packet.addressCount++];
            output.family = candidate->ai_family;
            output.socketType = candidate->ai_socktype;
            output.protocol = candidate->ai_protocol;
            output.length = static_cast<socklen_t>( candidate->ai_addrlen );
            std::memcpy( &output.address, candidate->ai_addr, candidate->ai_addrlen );
        }
    }
    if( addresses )
    {
        freeaddrinfo( addresses );
    }
}

bool buildResolverRequest( const Endpoint& endpoint, ResolverRequest& request )
{
    if( endpoint.host.size() > kMaximumResolverHostBytes || endpoint.port.size() >= request.port.size() )
    {
        return false;
    }
    request.hostLength = static_cast<std::uint32_t>( endpoint.host.size() );
    request.portLength = static_cast<std::uint32_t>( endpoint.port.size() );
    std::memcpy( request.host.data(), endpoint.host.data(), endpoint.host.size() );
    std::memcpy( request.port.data(), endpoint.port.data(), endpoint.port.size() );
#if defined( RIPWIRE_REDIS_TESTING )
    request.delayMilliseconds = redisTestHooks.resolverDelayMs;
    if( redisTestHooks.resolverAddresses.size() > request.overrideAddresses.size() )
    {
        return false;
    }
    request.overrideCount = static_cast<std::uint32_t>( redisTestHooks.resolverAddresses.size() );
    for( std::size_t addressIndex = 0; addressIndex < redisTestHooks.resolverAddresses.size(); ++addressIndex )
    {
        const std::string& address = redisTestHooks.resolverAddresses[addressIndex];
        if( address.size() >= request.overrideAddresses[addressIndex].size() )
        {
            return false;
        }
        std::memcpy( request.overrideAddresses[addressIndex].data(), address.data(), address.size() );
    }
#endif
    return true;
}

std::string currentExecutablePath()
{
#if defined( __APPLE__ )
    std::uint32_t size = 0;
    if( _NSGetExecutablePath( nullptr, &size ) != -1 || size == 0 )
    {
        return {};
    }
    std::vector<char> path( size );
    return _NSGetExecutablePath( path.data(), &size ) == 0 ? std::string( path.data() ) : std::string();
#elif defined( __linux__ )
    std::array<char, PATH_MAX + 1> path{};
    const ssize_t length = readlink( "/proc/self/exe", path.data(), path.size() - 1 );
    return length > 0 ? std::string( path.data(), static_cast<std::size_t>( length ) ) : std::string();
#elif defined( __FreeBSD__ )
    std::array<char, PATH_MAX + 1> path{};
    const ssize_t length = readlink( "/proc/curproc/file", path.data(), path.size() - 1 );
    return length > 0 ? std::string( path.data(), static_cast<std::size_t>( length ) ) : std::string();
#else
    return {};
#endif
}

bool addResolverDupAction( posix_spawn_file_actions_t& actions, const int descriptor, const int target ) noexcept
{
    return descriptor == target || posix_spawn_file_actions_adddup2( &actions, descriptor, target ) == 0;
}

bool addResolverCloseAction( posix_spawn_file_actions_t& actions, const int descriptor ) noexcept
{
    return descriptor == STDIN_FILENO || descriptor == STDOUT_FILENO || posix_spawn_file_actions_addclose( &actions, descriptor ) == 0;
}

bool addResolverSpawnActions( posix_spawn_file_actions_t& actions, const int requestInput, const int requestOutput, const int responseInput,
                              const int responseOutput ) noexcept
{
    return addResolverDupAction( actions, requestInput, STDIN_FILENO ) && addResolverDupAction( actions, responseOutput, STDOUT_FILENO )
           && addResolverCloseAction( actions, requestInput ) && addResolverCloseAction( actions, requestOutput )
           && addResolverCloseAction( actions, responseInput ) && addResolverCloseAction( actions, responseOutput );
}

pid_t spawnResolver( const std::string& executable, const int requestInput, const int requestOutput, const int responseInput,
                     const int responseOutput ) noexcept
{
    posix_spawn_file_actions_t actions;
    if( posix_spawn_file_actions_init( &actions ) != 0 )
    {
        return -1;
    }
    const bool actionsReady = addResolverSpawnActions( actions, requestInput, requestOutput, responseInput, responseOutput );
    pid_t processId = -1;
    char helperMode[] = "--redis-resolver-helper";
    char* arguments[]{ const_cast<char*>( executable.c_str() ), helperMode, nullptr };
    const int result = actionsReady ? posix_spawn( &processId, executable.c_str(), &actions, nullptr, arguments, environ ) : EINVAL;
    posix_spawn_file_actions_destroy( &actions );
    return result == 0 ? processId : -1;
}

bool writeResolverRequest( const int descriptor, const ResolverRequest& request, const Deadline deadline, bool& timedOut ) noexcept
{
    const char* bytes = reinterpret_cast<const char*>( &request );
    std::size_t written = 0;
    while( written < sizeof( request ) )
    {
        if( !waitForSocket( descriptor, POLLOUT, deadline, timedOut ) )
        {
            return false;
        }
        const ssize_t result = write( descriptor, bytes + written, sizeof( request ) - written );
        if( result > 0 )
        {
            written += static_cast<std::size_t>( result );
        }
        else if( result < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK )
        {
            return false;
        }
    }
    return true;
}

RedisFailure readResolverResponse( const int descriptor, const pid_t processId, const Deadline deadline, ResolverPacket& packet ) noexcept
{
    char* bytes = reinterpret_cast<char*>( &packet );
    std::size_t received = 0;
    while( received < sizeof( packet ) )
    {
        bool timedOut = false;
        if( !waitForSocket( descriptor, POLLIN, deadline, timedOut ) )
        {
            reapResolver( processId, true, deadline );
            return timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
        }
        const ssize_t result = read( descriptor, bytes + received, sizeof( packet ) - received );
        if( result > 0 )
        {
            received += static_cast<std::size_t>( result );
        }
        else if( result == 0 )
        {
            return reapResolver( processId, false, deadline ) ? RedisFailure::Connect : RedisFailure::Timeout;
        }
        else if( errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK )
        {
            reapResolver( processId, true, deadline );
            return RedisFailure::Connect;
        }
    }
    if( !reapResolver( processId, false, deadline ) )
    {
        return RedisFailure::Timeout;
    }
    if( packet.status != 0 || packet.addressCount == 0 || packet.addressCount > packet.addresses.size() )
    {
        return RedisFailure::Connect;
    }
    return RedisFailure::None;
}

RedisFailure resolveAddresses( const Endpoint& endpoint, const Deadline deadline, ResolverPacket& packet )
{
    ResolverRequest request;
    const std::string executable = currentExecutablePath();
    if( executable.empty() || !buildResolverRequest( endpoint, request ) )
    {
        return RedisFailure::Connect;
    }
    int requestDescriptors[2]{ -1, -1 };
    RedisFailure pipeFailure = retryPipe( requestDescriptors, InterruptibleCall::PipeRequest, deadline );
    if( pipeFailure != RedisFailure::None )
    {
        return pipeFailure;
    }
    SocketHandle requestInput( requestDescriptors[0] );
    SocketHandle requestOutput( requestDescriptors[1] );
    int responseDescriptors[2]{ -1, -1 };
    pipeFailure = retryPipe( responseDescriptors, InterruptibleCall::PipeResponse, deadline );
    if( pipeFailure != RedisFailure::None )
    {
        return pipeFailure;
    }
    SocketHandle responseInput( responseDescriptors[0] );
    SocketHandle responseOutput( responseDescriptors[1] );
    if( !setDescriptorFlags( requestOutput.get(), deadline ) || !setDescriptorFlags( responseInput.get(), deadline )
        || !setResolverChildDescriptorFlag( requestInput.get(), STDIN_FILENO, deadline )
        || !setResolverChildDescriptorFlag( responseOutput.get(), STDOUT_FILENO, deadline ) )
    {
        return remainingMilliseconds( deadline ) == 0 ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    const pid_t processId = spawnResolver( executable, requestInput.get(), requestOutput.get(), responseInput.get(), responseOutput.get() );
    if( processId < 0 )
    {
        return remainingMilliseconds( deadline ) == 0 ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    requestInput.reset();
    responseOutput.reset();
    bool timedOut = false;
    if( !writeResolverRequest( requestOutput.get(), request, deadline, timedOut ) )
    {
        reapResolver( processId, true, deadline );
        return timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    requestOutput.reset();
    return readResolverResponse( responseInput.get(), processId, deadline, packet );
}

RedisFailure finishConnect( const int descriptor, const sockaddr* address, const socklen_t addressLength, const Deadline deadline ) noexcept
{
    if( retryConnect( descriptor, address, addressLength, deadline ) == 0 )
    {
        return RedisFailure::None;
    }
    if( errno == ETIMEDOUT )
    {
        return RedisFailure::Timeout;
    }
    if( errno != EINPROGRESS && errno != EWOULDBLOCK )
    {
        return RedisFailure::Connect;
    }
    bool timedOut = false;
    if( !waitForSocket( descriptor, POLLOUT, deadline, timedOut ) )
    {
        return timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    int socketError = 0;
    socklen_t socketErrorLength = sizeof( socketError );
    if( retryGetSockOpt( descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength, deadline ) != 0 )
    {
        return errno == ETIMEDOUT ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    if( socketError != 0 )
    {
        return socketError == ETIMEDOUT ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    return RedisFailure::None;
}

bool validateResolvedAddresses( const ResolverPacket& addresses, const bool allowRemote ) noexcept
{
    for( std::size_t addressIndex = 0; addressIndex < addresses.addressCount; ++addressIndex )
    {
        const ResolvedAddress& candidate = addresses.addresses[addressIndex];
        if( ( candidate.family != AF_INET && candidate.family != AF_INET6 ) || candidate.length == 0 || candidate.length > sizeof( sockaddr_storage )
            || ( !allowRemote && !isLoopbackAddress( reinterpret_cast<const sockaddr*>( &candidate.address ) ) ) )
        {
            return false;
        }
    }
    return true;
}

SocketHandle createTcpSocket( const ResolvedAddress& candidate, const Deadline deadline ) noexcept
{
    int rawDescriptor = -1;
    while( rawDescriptor < 0 && remainingMilliseconds( deadline ) > 0 )
    {
        rawDescriptor = socket( candidate.family, candidate.socketType, candidate.protocol );
        if( rawDescriptor < 0 && errno != EINTR )
        {
            break;
        }
    }
    return SocketHandle( rawDescriptor );
}

RedisFailure validateTcpPeer( const int descriptor, const bool allowRemote, const Deadline deadline ) noexcept
{
    sockaddr_storage peer{};
    socklen_t peerLength = sizeof( peer );
    bool peerMismatch = false;
#if defined( RIPWIRE_REDIS_TESTING )
    peerMismatch = redisTestHooks.peerMismatch;
    redisTestHooks.peerMismatch = false;
#endif
    if( retryGetPeerName( descriptor, reinterpret_cast<sockaddr*>( &peer ), &peerLength, deadline ) != 0 )
    {
        return errno == ETIMEDOUT ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    return !peerMismatch && ( allowRemote || isLoopbackAddress( reinterpret_cast<const sockaddr*>( &peer ) ) ) ? RedisFailure::None
                                                                                                                : RedisFailure::Connect;
}

SocketHandle connectTcpCandidate( const ResolvedAddress& candidate, const bool allowRemote, const Deadline deadline, RedisFailure& failure )
{
    SocketHandle descriptor = createTcpSocket( candidate, deadline );
    if( !descriptor || !setDescriptorFlags( descriptor.get(), deadline ) )
    {
        return {};
    }
    failure = configureNoSigPipe( descriptor.get(), deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    failure = finishConnect( descriptor.get(), reinterpret_cast<const sockaddr*>( &candidate.address ), candidate.length, deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    failure = validateTcpPeer( descriptor.get(), allowRemote, deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    return descriptor;
}

SocketHandle connectTcp( const Endpoint& endpoint, const bool allowRemote, const Deadline deadline, RedisFailure& failure )
{
    ResolverPacket addresses;
    failure = resolveAddresses( endpoint, deadline, addresses );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    if( !validateResolvedAddresses( addresses, allowRemote ) )
    {
        failure = RedisFailure::Connect;
        return {};
    }
    RedisFailure lastFailure = RedisFailure::Connect;
    for( std::size_t addressIndex = 0; addressIndex < addresses.addressCount; ++addressIndex )
    {
        SocketHandle descriptor = connectTcpCandidate( addresses.addresses[addressIndex], allowRemote, deadline, lastFailure );
        if( !descriptor )
        {
            if( lastFailure == RedisFailure::Timeout )
            {
                break;
            }
            continue;
        }
        failure = RedisFailure::None;
        return descriptor;
    }
    failure = lastFailure;
    return {};
}

bool safeOwner( const uid_t owner ) noexcept
{
    return owner == 0 || owner == geteuid();
}

int retryPathStat( const char* path, struct stat* status, const bool noFollow, const Deadline deadline ) noexcept
{
    const InterruptibleCall call = noFollow ? InterruptibleCall::Lstat : InterruptibleCall::Stat;
    while( remainingMilliseconds( deadline ) > 0 )
    {
        const int result = injectInterruption( call ) ? -1 : ( noFollow ? lstat( path, status ) : stat( path, status ) );
        if( result == 0 || errno != EINTR )
        {
            return result;
        }
    }
    errno = ETIMEDOUT;
    return -1;
}

RedisFailure validateUnixParents( const std::string& path, const Deadline deadline ) noexcept
{
    std::string parent = "/";
    std::size_t position = 1;
    while( true )
    {
        const std::size_t slash = path.find( '/', position );
        if( slash == std::string::npos )
        {
            break;
        }
        if( parent.size() > 1 )
        {
            parent += '/';
        }
        parent.append( path, position, slash - position );
        struct stat status{};
        if( retryPathStat( parent.c_str(), &status, false, deadline ) != 0 )
        {
            return errno == ETIMEDOUT ? RedisFailure::Timeout : RedisFailure::Connect;
        }
        if( !S_ISDIR( status.st_mode ) || !safeOwner( status.st_uid ) || ( ( status.st_mode & 0022 ) != 0 && ( status.st_mode & S_ISVTX ) == 0 ) )
        {
            return RedisFailure::Connect;
        }
        position = slash + 1;
    }
    return RedisFailure::None;
}

RedisFailure validateUnixEndpoint( const std::string& path, struct stat& endpointStatus, const Deadline deadline ) noexcept
{
    bool unsafeOwner = false;
#if defined( RIPWIRE_REDIS_TESTING )
    unsafeOwner = redisTestHooks.unsafeUnixOwner;
    redisTestHooks.unsafeUnixOwner = false;
#endif
    if( retryPathStat( path.c_str(), &endpointStatus, true, deadline ) != 0 )
    {
        return errno == ETIMEDOUT ? RedisFailure::Timeout : RedisFailure::Connect;
    }
    return S_ISSOCK( endpointStatus.st_mode ) && !unsafeOwner && safeOwner( endpointStatus.st_uid ) && ( endpointStatus.st_mode & 0022 ) == 0
               ? RedisFailure::None
               : RedisFailure::Connect;
}

RedisFailure validateUnixPath( const std::string& path, struct stat& endpointStatus, const Deadline deadline ) noexcept
{
    const RedisFailure parentFailure = validateUnixParents( path, deadline );
    return parentFailure == RedisFailure::None ? validateUnixEndpoint( path, endpointStatus, deadline ) : parentFailure;
}

int getUnixPeerOwner( const int descriptor, uid_t& owner ) noexcept
{
#if defined( __APPLE__ ) || defined( __FreeBSD__ )
    gid_t effectiveGroup = 0;
    return getpeereid( descriptor, &owner, &effectiveGroup );
#elif defined( __linux__ ) && defined( SO_PEERCRED )
    struct PeerCredentials
    {
        pid_t processId;
        uid_t uid;
        gid_t gid;
    } credentials{};
    socklen_t length = sizeof( credentials );
    const int result = getsockopt( descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length );
    owner = credentials.uid;
    return result;
#else
    (void)descriptor;
    owner = geteuid();
    return 0;
#endif
}

RedisFailure validateUnixPeer( const int descriptor, const Deadline deadline ) noexcept
{
    uid_t owner = 0;
    while( remainingMilliseconds( deadline ) > 0 )
    {
        const int result = injectInterruption( InterruptibleCall::UnixPeer ) ? -1 : getUnixPeerOwner( descriptor, owner );
        if( result == 0 )
        {
            return safeOwner( owner ) ? RedisFailure::None : RedisFailure::Connect;
        }
        if( errno != EINTR )
        {
            return RedisFailure::Connect;
        }
    }
    return RedisFailure::Timeout;
}

SocketHandle openUnixSocket( const Deadline deadline, RedisFailure& failure ) noexcept
{
    int rawDescriptor = -1;
    while( rawDescriptor < 0 && remainingMilliseconds( deadline ) > 0 )
    {
        rawDescriptor = socket( AF_UNIX, SOCK_STREAM, 0 );
        if( rawDescriptor < 0 && errno != EINTR )
        {
            break;
        }
    }
    SocketHandle descriptor( rawDescriptor );
    if( !descriptor || !setDescriptorFlags( descriptor.get(), deadline ) )
    {
        failure = remainingMilliseconds( deadline ) == 0 ? RedisFailure::Timeout : RedisFailure::Connect;
        return {};
    }
    failure = configureNoSigPipe( descriptor.get(), deadline );
    return failure == RedisFailure::None ? std::move( descriptor ) : SocketHandle{};
}

RedisFailure validateConnectedUnix( const int descriptor, const std::string& path, const struct stat& before, const Deadline deadline ) noexcept
{
    struct stat after{};
    bool pathSwap = false;
#if defined( RIPWIRE_REDIS_TESTING )
    pathSwap = redisTestHooks.unixPathSwap;
    redisTestHooks.unixPathSwap = false;
#endif
    const RedisFailure pathFailure = validateUnixPath( path, after, deadline );
    if( pathFailure != RedisFailure::None )
    {
        return pathFailure;
    }
    if( pathSwap || before.st_dev != after.st_dev || before.st_ino != after.st_ino )
    {
        return RedisFailure::Connect;
    }
    return validateUnixPeer( descriptor, deadline );
}

SocketHandle connectUnix( const Endpoint& endpoint, const Deadline deadline, RedisFailure& failure )
{
    struct stat before{};
    if( endpoint.path.size() >= sizeof( sockaddr_un::sun_path ) )
    {
        failure = RedisFailure::Connect;
        return {};
    }
    failure = validateUnixPath( endpoint.path, before, deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    SocketHandle descriptor = openUnixSocket( deadline, failure );
    if( !descriptor )
    {
        return {};
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy( address.sun_path, endpoint.path.c_str(), endpoint.path.size() + 1 );
    failure = finishConnect( descriptor.get(), reinterpret_cast<const sockaddr*>( &address ), sizeof( address ), deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    failure = validateConnectedUnix( descriptor.get(), endpoint.path, before, deadline );
    if( failure != RedisFailure::None )
    {
        return {};
    }
    return descriptor;
}

bool charge( ParseContext& context, const std::size_t byteCount ) noexcept
{
    if( byteCount > context.aggregateLimit - std::min( context.aggregateBytes, context.aggregateLimit ) )
    {
        return false;
    }
    context.aggregateBytes += byteCount;
    return true;
}

ParseStatus readLine( ParseContext& context, std::string_view& line )
{
    const std::size_t end = context.input.find( "\r\n", context.position );
    if( end == std::string_view::npos )
    {
        return ParseStatus::NeedMore;
    }
    const std::size_t encodedLength = end + 2 - context.position;
    if( !charge( context, encodedLength ) )
    {
        return ParseStatus::Invalid;
    }
    line = context.input.substr( context.position, end - context.position );
    context.position = end + 2;
    return ParseStatus::Complete;
}

bool parseSigned( const std::string_view text, std::int64_t& value ) noexcept
{
    if( text.empty() || text.front() == '+' )
    {
        return false;
    }
    const bool isNegative = text.front() == '-';
    const std::string_view digits = isNegative ? text.substr( 1 ) : text;
    const std::uint64_t maximum = isNegative ? std::uint64_t( std::numeric_limits<std::int64_t>::max() ) + 1u
                                             : std::uint64_t( std::numeric_limits<std::int64_t>::max() );
    std::uint64_t magnitude = 0;
    if( !parseDecimalMagnitude( digits, maximum, magnitude ) )
    {
        return false;
    }
    if( isNegative && magnitude == maximum )
    {
        value = std::numeric_limits<std::int64_t>::min();
    }
    else
    {
        value = isNegative ? -static_cast<std::int64_t>( magnitude ) : static_cast<std::int64_t>( magnitude );
    }
    return true;
}

ParseStatus parseReply( ParseContext& context, RedisReply& reply, const std::size_t depth )
{
    if( depth > kMaximumReplyDepth || context.position >= context.input.size() )
    {
        return context.position >= context.input.size() ? ParseStatus::NeedMore : ParseStatus::Invalid;
    }
    if( ++context.nodeCount > kMaximumReplyNodes || !charge( context, sizeof( RedisReply ) ) )
    {
        return ParseStatus::Invalid;
    }
    const char prefix = context.input[context.position++];
    if( !charge( context, 1 ) )
    {
        return ParseStatus::Invalid;
    }
    std::string_view line;
    ParseStatus lineStatus = readLine( context, line );
    if( lineStatus != ParseStatus::Complete )
    {
        return lineStatus;
    }
    if( prefix == '+' || prefix == '-' )
    {
        reply.type = prefix == '+' ? RedisReplyType::Simple : RedisReplyType::Error;
        reply.bytes.assign( line );
        return ParseStatus::Complete;
    }
    if( prefix == ':' )
    {
        reply.type = RedisReplyType::Integer;
        return parseSigned( line, reply.integer ) ? ParseStatus::Complete : ParseStatus::Invalid;
    }
    if( prefix != '$' && prefix != '*' )
    {
        return ParseStatus::Invalid;
    }
    std::int64_t length = 0;
    if( !parseSigned( line, length ) || length < -1 )
    {
        return ParseStatus::Invalid;
    }
    if( length == -1 )
    {
        reply.type = RedisReplyType::Nil;
        return ParseStatus::Complete;
    }
    if( prefix == '$' )
    {
        if( static_cast<std::uint64_t>( length ) > kMaximumBulkBytes || !charge( context, static_cast<std::size_t>( length ) + 2 ) )
        {
            return ParseStatus::Invalid;
        }
        const std::size_t byteCount = static_cast<std::size_t>( length );
        if( byteCount > context.input.size() - std::min( context.position, context.input.size() ) || context.input.size() - context.position < byteCount + 2 )
        {
            return ParseStatus::NeedMore;
        }
        if( context.input.substr( context.position + byteCount, 2 ) != "\r\n" )
        {
            return ParseStatus::Invalid;
        }
        reply.type = RedisReplyType::Bulk;
        reply.bytes.assign( context.input.substr( context.position, byteCount ) );
        context.position += byteCount + 2;
        return ParseStatus::Complete;
    }
    if( static_cast<std::uint64_t>( length ) > kMaximumArrayElements )
    {
        return ParseStatus::Invalid;
    }
    const std::size_t elementCount = static_cast<std::size_t>( length );
    if( elementCount > ( context.aggregateLimit - std::min( context.aggregateBytes, context.aggregateLimit ) ) / sizeof( RedisReply ) )
    {
        return ParseStatus::Invalid;
    }
    reply.type = RedisReplyType::Array;
    reply.elements.reserve( elementCount );
    for( std::size_t elementIndex = 0; elementIndex < elementCount; ++elementIndex )
    {
        RedisReply element;
        const ParseStatus status = parseReply( context, element, depth + 1 );
        if( status != ParseStatus::Complete )
        {
            return status;
        }
        reply.elements.push_back( std::move( element ) );
    }
    return ParseStatus::Complete;
}

ParseOutcome parseReplies( const std::string_view input, const std::size_t expectedReplyCount, const std::size_t aggregateLimit )
{
    ParseOutcome outcome;
    ParseContext context{ input, 0, 0, 0, aggregateLimit };
    outcome.replies.reserve( expectedReplyCount );
    for( std::size_t replyIndex = 0; replyIndex < expectedReplyCount; ++replyIndex )
    {
        RedisReply reply;
        const ParseStatus status = parseReply( context, reply, 0 );
        if( status != ParseStatus::Complete )
        {
            outcome.status = status;
            outcome.replies.clear();
            return outcome;
        }
        outcome.replies.push_back( std::move( reply ) );
    }
    outcome.status = context.position == input.size() ? ParseStatus::Complete : ParseStatus::Invalid;
    if( outcome.status != ParseStatus::Complete )
    {
        outcome.replies.clear();
    }
    return outcome;
}

std::string errorCategory( const std::string_view error )
{
    constexpr std::array<std::string_view, 8> categories{ "ERR", "WRONGPASS", "NOAUTH", "BUSY", "NOSCRIPT", "READONLY", "OOM", "MISCONF" };
    for( const std::string_view category : categories )
    {
        if( error == category || ( error.starts_with( category ) && error.size() > category.size() && error[category.size()] == ' ' ) )
        {
            return std::string( category );
        }
    }
    return "ERR";
}

RedisFailure errorFailure( const std::string_view error, const bool authenticating )
{
    if( error.starts_with( "MOVED " ) || error.starts_with( "ASK " ) )
    {
        return RedisFailure::ClusterRedirect;
    }
    if( authenticating || error.starts_with( "NOAUTH" ) || error.starts_with( "WRONGPASS" ) )
    {
        return RedisFailure::Auth;
    }
    return RedisFailure::Server;
}

RedisResult classifiedReplyError( RedisReply reply, const std::string_view endpointClass, const bool authenticating )
{
    const RedisFailure failure = errorFailure( reply.bytes, authenticating );
    RedisResult result = failureResult( failure, endpointClass,
                                        failure == RedisFailure::ClusterRedirect ? std::string_view() : std::string_view( errorCategory( reply.bytes ) ) );
    result.reply = std::move( reply );
    return result;
}

bool appendDecimal( std::string& destination, const std::size_t value )
{
    std::array<char, 32> buffer{};
    const auto result = std::to_chars( buffer.data(), buffer.data() + buffer.size(), value );
    if( result.ec != std::errc() )
    {
        return false;
    }
    destination.append( buffer.data(), result.ptr );
    return true;
}

std::size_t decimalDigitCount( std::size_t value ) noexcept
{
    std::size_t count = 1;
    while( value >= 10 )
    {
        value /= 10;
        ++count;
    }
    return count;
}

bool addEncodedBytes( std::size_t& total, const std::size_t additional ) noexcept
{
    if( additional > kMaximumRequestBytes || total > kMaximumRequestBytes - additional )
    {
        return false;
    }
    total += additional;
    return true;
}

bool encodedBatchSize( const std::vector<std::vector<std::string_view>>& commands, std::size_t& encodedSize ) noexcept
{
    std::size_t total = 0;
    for( const std::vector<std::string_view>& arguments : commands )
    {
        if( arguments.empty() || !addEncodedBytes( total, 3 + decimalDigitCount( arguments.size() ) ) )
        {
            return false;
        }
        for( const std::string_view argument : arguments )
        {
            const std::size_t framing = 5 + decimalDigitCount( argument.size() );
            if( !addEncodedBytes( total, framing ) || !addEncodedBytes( total, argument.size() ) )
            {
                return false;
            }
        }
    }
    encodedSize = total;
    return true;
}

bool appendCommand( std::string& destination, const std::vector<std::string_view>& arguments )
{
    destination.push_back( '*' );
    if( !appendDecimal( destination, arguments.size() ) )
    {
        return false;
    }
    destination += "\r\n";
    for( const std::string_view argument : arguments )
    {
        destination.push_back( '$' );
        if( !appendDecimal( destination, argument.size() ) )
        {
            return false;
        }
        destination += "\r\n";
        destination.append( argument.data(), argument.size() );
        destination += "\r\n";
    }
    return true;
}

RedisFailure sendAll( const int descriptor, const std::string_view bytes, const Deadline deadline ) noexcept
{
    std::size_t sent = 0;
    while( sent < bytes.size() )
    {
        if( remainingMilliseconds( deadline ) == 0 )
        {
            return RedisFailure::Timeout;
        }
#if defined( MSG_NOSIGNAL )
        constexpr int sendFlags = MSG_NOSIGNAL;
#else
        constexpr int sendFlags = 0;
#endif
        const ssize_t result = send( descriptor, bytes.data() + sent, bytes.size() - sent, sendFlags );
        if( result > 0 )
        {
            sent += static_cast<std::size_t>( result );
            continue;
        }
        if( result < 0 && errno == EINTR )
        {
            continue;
        }
        if( result < 0 && ( errno == EAGAIN || errno == EWOULDBLOCK ) )
        {
            bool timedOut = false;
            if( !waitForSocket( descriptor, POLLOUT, deadline, timedOut ) )
            {
                return timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
            }
            continue;
        }
        return RedisFailure::Connect;
    }
    return RedisFailure::None;
}

struct ReceiveResult
{
    RedisFailure failure = RedisFailure::None;
    std::vector<RedisReply> replies;
};

ReceiveResult receiveReplies( const int descriptor, const std::size_t expectedReplyCount, const Deadline deadline )
{
    ReceiveResult result;
    std::string bytes;
    std::array<char, 64u * 1024u> buffer{};
    while( true )
    {
        const ParseOutcome parsed = parseReplies( bytes, expectedReplyCount, kMaximumAggregateBytes );
        if( parsed.status == ParseStatus::Complete )
        {
            result.replies = parsed.replies;
            return result;
        }
        if( parsed.status == ParseStatus::Invalid || bytes.size() >= kMaximumAggregateBytes )
        {
            result.failure = RedisFailure::Protocol;
            return result;
        }
        bool timedOut = false;
        if( !waitForSocket( descriptor, POLLIN, deadline, timedOut ) )
        {
            result.failure = timedOut ? RedisFailure::Timeout : RedisFailure::Connect;
            return result;
        }
        const ssize_t received = recv( descriptor, buffer.data(), std::min( buffer.size(), kMaximumAggregateBytes - bytes.size() ), 0 );
        if( received > 0 )
        {
            bytes.append( buffer.data(), static_cast<std::size_t>( received ) );
            continue;
        }
        if( received < 0 && errno == EINTR )
        {
            continue;
        }
        if( received < 0 && ( errno == EAGAIN || errno == EWOULDBLOCK ) )
        {
            continue;
        }
        result.failure = bytes.empty() ? RedisFailure::Connect : RedisFailure::Protocol;
        return result;
    }
}

bool encodeCommands( const std::vector<std::vector<std::string_view>>& commands, std::string& encoded )
{
    std::size_t encodedSize = 0;
    if( !encodedBatchSize( commands, encodedSize ) )
    {
        return false;
    }
    encoded.clear();
    encoded.reserve( encodedSize );
    for( const std::vector<std::string_view>& command : commands )
    {
        if( !appendCommand( encoded, command ) )
        {
            return false;
        }
    }
    return encoded.size() == encodedSize;
}

RedisResult exchangeHandshake( const int descriptor, const std::vector<std::string_view>& command, const Deadline deadline,
                               const std::string_view endpointClass, const bool authentication )
{
    std::string encoded;
    if( !encodeCommands( { command }, encoded ) )
    {
        return failureResult( RedisFailure::Config, endpointClass );
    }
    const RedisFailure sendFailure = sendAll( descriptor, encoded, deadline );
    if( sendFailure != RedisFailure::None )
    {
        return failureResult( sendFailure, endpointClass );
    }
    ReceiveResult received = receiveReplies( descriptor, 1, deadline );
    if( received.failure != RedisFailure::None )
    {
        return failureResult( received.failure, endpointClass );
    }
    RedisReply& reply = received.replies[0];
    if( reply.type == RedisReplyType::Error )
    {
        return classifiedReplyError( std::move( reply ), endpointClass, authentication );
    }
    if( reply.type != RedisReplyType::Simple || reply.bytes != "OK" )
    {
        return failureResult( RedisFailure::Protocol, endpointClass );
    }
    return {};
}

}

int runRedisResolverHelperIfRequested( const int argumentCount, char** arguments )
{
    if( argumentCount != 2 || std::string_view( arguments[1] ) != "--redis-resolver-helper" )
    {
        return -1;
    }
    ResolverRequest request;
    if( !readFixedPacket( STDIN_FILENO, &request, sizeof( request ) ) || !validateResolverRequest( request ) )
    {
        return 1;
    }
    ResolverPacket packet;
    resolveRequest( request, packet );
    return writeFixedPacket( STDOUT_FILENO, &packet, sizeof( packet ) ) ? 0 : 1;
}

RedisClient::RedisClient( RedisCacheConfig config ) : config_( std::move( config ) ) {}

namespace
{
CacheProbeStatus probeFileCacheBlob( const CacheBlobAddress& address, std::string& bytes )
{
    if( address.fileProbe == nullptr ) { return CacheProbeStatus::Unavailable; }
    const int hit = address.fileProbe( address.localPath, bytes );
    return hit == 1 ? CacheProbeStatus::Hit : hit < 0 ? CacheProbeStatus::Corrupt : CacheProbeStatus::Miss;
}

// External components are always hashed separately; no user byte can introduce a key delimiter.
std::string cacheBlobKey( const CacheContext& cache, const CacheBlobAddress& address )
{
    const char* family = nullptr;
    switch( address.family )
    {
        case CacheBlobFamily::QualitySnapshot: family = "qsnap"; break;
        case CacheBlobFamily::QualityBody: family = "qbody"; break;
        case CacheBlobFamily::QualityChurn: family = "qchurn"; break;
        case CacheBlobFamily::GitOracle: family = "qhist"; break;
        case CacheBlobFamily::SpanTier: family = "stier"; break;
        case CacheBlobFamily::DocumentExtraction: family = "docmd"; break;
    }
    if( family == nullptr || address.artifactArch != kArtifactArch || cache.project.empty() ) { return {}; }
    const std::string key = "ripwire:" + redisKeyHash( cache.policy->redis.nameSpace ) + ":" + redisKeyHash( cache.project ) + ":" + family
         + ":" + std::to_string( address.schemeVersion ) + ":" + std::to_string( address.artifactArch ) + ":" + redisKeyHash( address.identity );
    return key.size() <= 512 ? key : std::string{};
}
}

CacheProbeStatus probeCacheBlob( const CacheContext& cache, const CacheBlobAddress& address, std::string& bytes )
{
    bytes.clear();
    const auto kind = cache.policy ? cache.policy->kind : CacheBackendKind::File;
    if( kind == CacheBackendKind::Disabled ) { return CacheProbeStatus::Miss; }
    if( kind == CacheBackendKind::File )
    {
        return probeFileCacheBlob( address, bytes );
    }
    const std::string key = cacheBlobKey( cache, address );
    if( key.empty() ) { return CacheProbeStatus::Miss; }
    const RedisClient client( cache.policy->redis );
    const RedisResult result = client.command( { "GET", key } );
    if( !result ) { redisIngestDegraded( result.failure ); return CacheProbeStatus::Unavailable; }
    if( result.reply.type == RedisReplyType::Nil ) { return CacheProbeStatus::Miss; }
    const std::string& envelope = result.reply.bytes;
    if( result.reply.type != RedisReplyType::Bulk || envelope.size() < 68 || envelope.size() > kMaximumBulkBytes
        || envelope.compare( 0, 4, "RWB1" ) != 0
        || envelope.substr( 4, 64 ) != redisKeyHash( key + envelope.substr( 68 ) ) )
    {
        redisIngestDegraded();
        return CacheProbeStatus::Corrupt;
    }
    bytes.assign( envelope, 68, std::string::npos );
    const RedisResult refreshed = client.command( { "EXPIRE", key, std::to_string( cache.policy->redis.ttlSeconds ) } );
    if( !refreshed ) { redisIngestDegraded( refreshed.failure ); }
    else if( refreshed.reply.type != RedisReplyType::Integer || ( refreshed.reply.integer != 0 && refreshed.reply.integer != 1 ) )
    {
        redisIngestDegraded( RedisFailure::Protocol );
    }
    return CacheProbeStatus::Hit;
}

bool storeCacheBlob( const CacheContext& cache, const CacheBlobAddress& address, const std::string& bytes )
{
    const auto kind = cache.policy ? cache.policy->kind : CacheBackendKind::File;
    if( kind == CacheBackendKind::Disabled ) { return false; }
    if( kind == CacheBackendKind::File )
    {
        return address.fileStore != nullptr && address.fileStore( address.localPath, bytes );
    }
    const std::string key = cacheBlobKey( cache, address );
    if( key.empty() || bytes.size() > kMaximumBulkBytes - 68 ) { return false; }
    const RedisClient client( cache.policy->redis );
    const std::string envelope = "RWB1" + redisKeyHash( key + bytes ) + bytes;
    const RedisResult result = client.command( { "SET", key, envelope, "EX", std::to_string( cache.policy->redis.ttlSeconds ) } );
    if( !result || result.reply.type != RedisReplyType::Simple || result.reply.bytes != "OK" )
    {
        redisIngestDegraded( result ? RedisFailure::Protocol : result.failure );
        return false;
    }
    return true;
}

RedisResult RedisClient::command( const std::vector<std::string_view>& arguments ) const
{
    return execute( { arguments } );
}

RedisResult RedisClient::pipeline( const std::vector<std::vector<std::string>>& commands ) const
{
    std::vector<std::vector<std::string_view>> views;
    views.reserve( commands.size() );
    for( const std::vector<std::string>& command : commands )
    {
        std::vector<std::string_view> arguments;
        arguments.reserve( command.size() );
        for( const std::string& argument : command )
        {
            arguments.push_back( argument );
        }
        views.push_back( std::move( arguments ) );
    }
    return execute( views );
}

RedisResult RedisClient::execute( const std::vector<std::vector<std::string_view>>& commands ) const
{
    Endpoint endpoint;
    const EndpointKind diagnosticKind = config_.endpoint.starts_with( "redis+unix://" ) ? EndpointKind::Unix : EndpointKind::Tcp;
    const std::string endpointClass = endpointName( diagnosticKind );
    if( config_.timeoutMs == 0 || commands.empty() || commands.size() > kMaximumPipelineCommands || !parseEndpoint( config_.endpoint, endpoint )
        || ( config_.username.empty() && !config_.password.empty() && config_.password.size() > kMaximumRequestBytes )
        || ( !config_.username.empty() && config_.password.empty() ) )
    {
        return failureResult( RedisFailure::Config, endpointClass );
    }

    std::vector<std::vector<std::string_view>> requests;
    requests.reserve( commands.size() + 2 );
    std::vector<std::string_view> authentication;
    if( !config_.password.empty() )
    {
        authentication.push_back( "AUTH" );
        if( !config_.username.empty() )
        {
            authentication.push_back( config_.username );
        }
        authentication.push_back( config_.password );
        requests.push_back( authentication );
    }
    const std::string database = std::to_string( endpoint.database );
    if( endpoint.database != 0 )
    {
        requests.push_back( { "SELECT", database } );
    }
    requests.insert( requests.end(), commands.begin(), commands.end() );

    std::size_t totalEncodedSize = 0;
    if( !encodedBatchSize( requests, totalEncodedSize ) )
    {
        return failureResult( RedisFailure::Config, endpointClass );
    }
    std::string encoded;
    if( !encodeCommands( commands, encoded ) )
    {
        return failureResult( RedisFailure::Config, endpointClass );
    }

    const Deadline deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( config_.timeoutMs );
    RedisFailure connectFailure = RedisFailure::Connect;
    SocketHandle socket = endpoint.kind == EndpointKind::Tcp ? connectTcp( endpoint, config_.allowPlaintextRemote, deadline, connectFailure )
                                                              : connectUnix( endpoint, deadline, connectFailure );
    if( !socket )
    {
        return failureResult( connectFailure, endpointClass );
    }
    if( !config_.password.empty() )
    {
        const RedisResult handshake = exchangeHandshake( socket.get(), authentication, deadline, endpointClass, true );
        if( !handshake )
        {
            return handshake;
        }
    }
    if( endpoint.database != 0 )
    {
        const RedisResult handshake = exchangeHandshake( socket.get(), { "SELECT", database }, deadline, endpointClass, false );
        if( !handshake )
        {
            return handshake;
        }
    }
    const RedisFailure sendFailure = sendAll( socket.get(), encoded, deadline );
    if( sendFailure != RedisFailure::None )
    {
        return failureResult( sendFailure, endpointClass );
    }
    ReceiveResult received = receiveReplies( socket.get(), commands.size(), deadline );
    if( received.failure != RedisFailure::None )
    {
        return failureResult( received.failure, endpointClass );
    }

    for( std::size_t replyIndex = 0; replyIndex < received.replies.size(); ++replyIndex )
    {
        if( received.replies[replyIndex].type == RedisReplyType::Error )
        {
            return classifiedReplyError( std::move( received.replies[replyIndex] ), endpointClass, false );
        }
    }
    RedisResult result;
    if( commands.size() == 1 )
    {
        result.reply = std::move( received.replies[0] );
    }
    else
    {
        result.reply.type = RedisReplyType::Array;
        result.reply.elements.reserve( commands.size() );
        for( std::size_t replyIndex = 0; replyIndex < received.replies.size(); ++replyIndex )
        {
            result.reply.elements.push_back( std::move( received.replies[replyIndex] ) );
        }
    }
    return result;
}

RedisResult RedisClient::parseReplyForTesting( const std::string_view bytes, const std::size_t aggregateLimit )
{
    ParseOutcome parsed = parseReplies( bytes, 1, aggregateLimit );
    if( parsed.status != ParseStatus::Complete )
    {
        return failureResult( RedisFailure::Protocol, "reply" );
    }
    if( parsed.replies[0].type == RedisReplyType::Error )
    {
        return classifiedReplyError( std::move( parsed.replies[0] ), "reply", false );
    }
    RedisResult result;
    result.reply = std::move( parsed.replies[0] );
    return result;
}

RedisResult RedisClient::parseReplyChunksForTesting( const std::vector<std::string_view>& chunks )
{
    std::string bytes;
    for( std::size_t chunkIndex = 0; chunkIndex < chunks.size(); ++chunkIndex )
    {
        bytes.append( chunks[chunkIndex] );
        const ParseOutcome parsed = parseReplies( bytes, 1, kMaximumAggregateBytes );
        if( chunkIndex + 1 < chunks.size() && parsed.status != ParseStatus::NeedMore )
        {
            return failureResult( RedisFailure::Protocol, "reply" );
        }
    }
    return parseReplyForTesting( bytes );
}

bool RedisClient::encodedBatchSizeForTesting( const std::vector<std::vector<std::string_view>>& commands, std::size_t& size )
{
    return encodedBatchSize( commands, size );
}

void RedisClient::injectEintrForTesting()
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.eintr.fill( 1 );
#endif
}

void RedisClient::injectRepeatedEintrForTesting( const std::string_view call, const unsigned count )
{
#if defined( RIPWIRE_REDIS_TESTING )
    constexpr std::array<std::string_view, static_cast<std::size_t>( InterruptibleCall::Count )> names{
        "pipe-request", "pipe-response", "fcntl", "connect", "getsockopt", "getpeername", "stat", "lstat", "unix-peer"
    };
    for( std::size_t callIndex = 0; callIndex < names.size(); ++callIndex )
    {
        if( call == names[callIndex] )
        {
            redisTestHooks.eintr[callIndex] = count;
            return;
        }
    }
#else
    (void)call;
    (void)count;
#endif
}

void RedisClient::setResolverDelayForTesting( const std::uint32_t milliseconds )
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.resolverDelayMs = milliseconds;
#else
    (void)milliseconds;
#endif
}

void RedisClient::setResolverAddressesForTesting( std::vector<std::string> addresses )
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.resolverAddresses = std::move( addresses );
#else
    (void)addresses;
#endif
}

void RedisClient::setPeerMismatchForTesting()
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.peerMismatch = true;
#endif
}

void RedisClient::setUnixPathSwapForTesting()
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.unixPathSwap = true;
#endif
}

void RedisClient::setUnsafeUnixOwnerForTesting()
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.unsafeUnixOwner = true;
#endif
}

void RedisClient::setNoSigPipeFailureForTesting()
{
#if defined( RIPWIRE_REDIS_TESTING )
    redisTestHooks.noSigPipeFailure = true;
#endif
}

}
