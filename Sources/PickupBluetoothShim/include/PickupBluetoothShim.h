// Raw AT line tap for AppleHFPTransport (taken over from the phase 0 spike, prefix PUB).
//
// IOBluetoothHandsFreeDevice consumes most AT traffic internally (RING, +CIEV, +CIND, OK, the
// whole SLC setup) and only forwards a digested subset to its delegate. The project rule is to
// log every AT command and response, and the transport needs the raw lines to correlate final
// result codes with commands (complete AT+CLCC lists, ATD errors). So this shim taps the raw
// RFCOMM byte stream:
//   - incoming: PUBLoggingHandsFreeDevice overrides the RFCOMM delegate callback
//     -rfcommChannelData:data:length:, logs the bytes, then calls super.
//   - outgoing: PUBInstallRFCOMMWriteLogging() replaces the write methods of
//     IOBluetoothRFCOMMChannel with wrappers that log, then call the original implementation.
// Both hooks are logging-only and never change the bytes. PacketLogger stays the ground truth.

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PUBATDirection) {
    /// Mac (hands-free unit) -> phone (audio gateway)
    PUBATDirectionOutgoing = 0,
    /// Phone (audio gateway) -> Mac (hands-free unit)
    PUBATDirectionIncoming = 1,
};

/// Called once per complete AT line (CR/LF stripped). `detail` carries extra context such as
/// the RFCOMM write method or a non-zero IOReturn, or is nil.
typedef void (^PUBATLogHandler)(PUBATDirection direction, NSString *line, NSString *_Nullable detail);

/// Called once per complete outgoing AT line with the channel it was written to, so a caller can
/// ignore writes on channels that are not its own. A failed write is reported as the line
/// "(write failed)" with the IOReturn in `detail`.
typedef void (^PUBATWriteHandler)(IOBluetoothRFCOMMChannel *channel, NSString *line, NSString *_Nullable detail);

/// Installs process-wide logging of all IOBluetoothRFCOMMChannel writes. Idempotent; the most
/// recent handler wins. Returns the number of write methods that were hooked.
NSInteger PUBInstallRFCOMMWriteLogging(PUBATWriteHandler handler);

/// Reassembles AT lines from RFCOMM chunks. A line is only emitted once its CR or LF has
/// arrived, so a number split across two chunks is logged (and redacted) as one piece.
/// Bytes are decoded as UTF-8, falling back to ISO Latin-1; control characters and other
/// non-printables are shown as \xNN. Not thread-safe; callers serialise access.
@interface PUBATLineAssembler : NSObject
/// Lines longer than this without a terminator are flushed with a "[partial]" suffix.
@property (nonatomic) NSUInteger maximumLineLength;
- (NSArray<NSString *> *)appendBytes:(const void *)bytes length:(size_t)length;
@end

@interface PUBLoggingHandsFreeDevice : IOBluetoothHandsFreeDevice

/// Receives every complete incoming AT line before IOBluetooth processes the chunk.
@property (nonatomic, copy, nullable) PUBATLogHandler incomingHandler;

/// The RFCOMM channel this object last received data on (weak).
@property (nonatomic, weak, readonly, nullable) IOBluetoothRFCOMMChannel *observedChannel;

/// True if `channel` belongs to this object: it is the channel's delegate, or data arrived on it.
- (BOOL)ownsChannel:(IOBluetoothRFCOMMChannel *)channel;

@end

NS_ASSUME_NONNULL_END
