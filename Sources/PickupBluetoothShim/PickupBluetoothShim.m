#import "PickupBluetoothShim.h"
#import <objc/runtime.h>

#if !__has_feature(objc_arc)
#error "PickupBluetoothShim must be compiled with ARC (-fobjc-arc)."
#endif

#pragma mark - Line assembly

static NSString *PKDecodeLine(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) {
        // Latin-1 maps every byte, so digits stay digits and remain redactable.
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    NSMutableString *escaped = [NSMutableString stringWithCapacity:text.length];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        unichar first = [character characterAtIndex:0];
        BOOL control = first < 0x20 || first == 0x7f || (first >= 0x80 && first < 0xa0);
        if (control) {
            [escaped appendFormat:@"\\x%02x", first];
        } else {
            [escaped appendString:character];
        }
    }];
    return escaped;
}

@implementation PUBATLineAssembler {
    NSMutableData *_pending;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pending = [NSMutableData data];
        _maximumLineLength = 4096;
    }
    return self;
}

- (NSArray<NSString *> *)appendBytes:(const void *)bytes length:(size_t)length {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (bytes == NULL || length == 0) {
        return lines;
    }
    const uint8_t *p = bytes;
    for (size_t i = 0; i < length; i++) {
        uint8_t byte = p[i];
        if (byte == '\r' || byte == '\n') {
            if (_pending.length > 0) {
                [lines addObject:PKDecodeLine(_pending)];
                _pending = [NSMutableData data];
            }
            continue;
        }
        [_pending appendBytes:&byte length:1];
        if (_pending.length >= _maximumLineLength) {
            [lines addObject:[PKDecodeLine(_pending) stringByAppendingString:@" [partial]"]];
            _pending = [NSMutableData data];
        }
    }
    return lines;
}

@end

#pragma mark - Outgoing: RFCOMM write hooks

// Reentrancy guard: one public write method may be implemented on top of another one.
// Only the outermost call on a thread is logged, so nothing is logged twice.
static __thread int pk_writeDepth = 0;
static PUBATWriteHandler pk_writeHandler = nil;
// One line assembler per channel (weak keys), so partial lines of two channels never interleave.
static NSMapTable<IOBluetoothRFCOMMChannel *, PUBATLineAssembler *> *pk_writeAssemblers = nil;

static void PKLogWrite(IOBluetoothRFCOMMChannel *channel, const void *data, UInt16 length, NSString *method) {
    if (pk_writeDepth != 1) {
        return;
    }
    PUBATWriteHandler handler;
    NSArray<NSString *> *lines;
    @synchronized ([IOBluetoothRFCOMMChannel class]) {
        handler = pk_writeHandler;
        PUBATLineAssembler *assembler = channel ? [pk_writeAssemblers objectForKey:channel] : nil;
        if (assembler == nil) {
            assembler = [PUBATLineAssembler new];
            if (channel != nil) {
                [pk_writeAssemblers setObject:assembler forKey:channel];
            }
        }
        lines = [assembler appendBytes:data length:length];
    }
    if (handler == nil) {
        return;
    }
    for (NSString *line in lines) {
        handler(channel, line, method);
    }
}

static void PKLogWriteResult(IOBluetoothRFCOMMChannel *channel, IOReturn result, NSString *method) {
    PUBATWriteHandler handler = pk_writeHandler;
    if (handler == nil || pk_writeDepth != 1 || result == kIOReturnSuccess) {
        return;
    }
    handler(channel, @"(write failed)",
            [NSString stringWithFormat:@"%@ returned 0x%08x", method, result]);
}

typedef IOReturn (*PKWriteSyncIMP)(id, SEL, void *, UInt16);
typedef IOReturn (*PKWriteAsyncIMP)(id, SEL, void *, UInt16, void *);
typedef IOReturn (*PKWriteSleepIMP)(id, SEL, void *, UInt16, BOOL);
typedef IOReturn (*PKWriteSimpleIMP)(id, SEL, void *, UInt16, BOOL, UInt32 *);

// Runs `write` with logging around it; pk_writeDepth is restored even if `write` throws.
static IOReturn PKLoggedWrite(id channel, void *data, UInt16 length, NSString *method, IOReturn (^write)(void)) {
    IOReturn result = kIOReturnError;
    pk_writeDepth++;
    @try {
        PKLogWrite(channel, data, length, method);
        result = write();
        PKLogWriteResult(channel, result, method);
    } @finally {
        pk_writeDepth--;
    }
    return result;
}

static BOOL pk_hooksInstalled = NO;
static NSInteger pk_hookCount = 0;

static Method PKFindMethod(Class cls, NSString *selectorName) {
    return class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
}

NSInteger PUBInstallRFCOMMWriteLogging(PUBATWriteHandler handler) {
    @synchronized ([IOBluetoothRFCOMMChannel class]) {
        pk_writeHandler = [handler copy];
        if (pk_hooksInstalled) {
            return pk_hookCount;
        }
        pk_hooksInstalled = YES;
        pk_writeAssemblers = [NSMapTable weakToStrongObjectsMapTable];

        Class cls = [IOBluetoothRFCOMMChannel class];
        Method m;

        if ((m = PKFindMethod(cls, @"writeSync:length:"))) {
            PKWriteSyncIMP original = (PKWriteSyncIMP)method_getImplementation(m);
            SEL sel = method_getName(m);
            method_setImplementation(m, imp_implementationWithBlock(^IOReturn(id self_, void *data, UInt16 length) {
                return PKLoggedWrite(self_, data, length, @"writeSync", ^IOReturn {
                    return original(self_, sel, data, length);
                });
            }));
            pk_hookCount++;
        }

        if ((m = PKFindMethod(cls, @"writeAsync:length:refcon:"))) {
            PKWriteAsyncIMP original = (PKWriteAsyncIMP)method_getImplementation(m);
            SEL sel = method_getName(m);
            method_setImplementation(m, imp_implementationWithBlock(^IOReturn(id self_, void *data, UInt16 length, void *refcon) {
                return PKLoggedWrite(self_, data, length, @"writeAsync", ^IOReturn {
                    return original(self_, sel, data, length, refcon);
                });
            }));
            pk_hookCount++;
        }

        // The two deprecated variants are hooked too, in case IOBluetooth still uses them internally.
        if ((m = PKFindMethod(cls, @"write:length:sleep:"))) {
            PKWriteSleepIMP original = (PKWriteSleepIMP)method_getImplementation(m);
            SEL sel = method_getName(m);
            method_setImplementation(m, imp_implementationWithBlock(^IOReturn(id self_, void *data, UInt16 length, BOOL sleep) {
                return PKLoggedWrite(self_, data, length, @"write:sleep", ^IOReturn {
                    return original(self_, sel, data, length, sleep);
                });
            }));
            pk_hookCount++;
        }

        if ((m = PKFindMethod(cls, @"writeSimple:length:sleep:bytesSent:"))) {
            PKWriteSimpleIMP original = (PKWriteSimpleIMP)method_getImplementation(m);
            SEL sel = method_getName(m);
            method_setImplementation(m, imp_implementationWithBlock(^IOReturn(id self_, void *data, UInt16 length, BOOL sleep, UInt32 *sent) {
                return PKLoggedWrite(self_, data, length, @"writeSimple", ^IOReturn {
                    return original(self_, sel, data, length, sleep, sent);
                });
            }));
            pk_hookCount++;
        }

        return pk_hookCount;
    }
}

#pragma mark - Incoming: RFCOMM data override

// IOBluetoothHandsFree implements the RFCOMM channel delegate method but does not declare it
// publicly. Declaring it here lets the subclass call super.
@interface IOBluetoothHandsFree (PUBRFCOMMDelegate)
- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel data:(void *)dataPointer length:(size_t)dataLength;
@end

@implementation PUBLoggingHandsFreeDevice {
    BOOL _loggedChannelClass;
    PUBATLineAssembler *_incomingAssembler;
    NSString *_channelDetail; // attached to the first complete incoming line, then cleared
}

- (BOOL)ownsChannel:(IOBluetoothRFCOMMChannel *)channel {
    if (channel == nil) {
        return NO;
    }
    return [channel delegate] == self || channel == self.observedChannel;
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel data:(void *)dataPointer length:(size_t)dataLength {
    _observedChannel = rfcommChannel;
    PUBATLogHandler handler = self.incomingHandler;
    if (handler != nil) {
        if (_incomingAssembler == nil) {
            _incomingAssembler = [PUBATLineAssembler new];
        }
        if (!_loggedChannelClass) {
            // If the channel is a private subclass that overrides the write methods, the outgoing
            // hooks on IOBluetoothRFCOMMChannel would miss them. Log the class once to make that visible.
            _loggedChannelClass = YES;
            _channelDetail = [NSString stringWithFormat:@"channel class %@, id %u",
                              NSStringFromClass([rfcommChannel class]), (unsigned)[rfcommChannel getChannelID]];
        }
        for (NSString *line in [_incomingAssembler appendBytes:dataPointer length:dataLength]) {
            handler(PUBATDirectionIncoming, line, _channelDetail);
            _channelDetail = nil;
        }
    }
    if ([IOBluetoothHandsFreeDevice instancesRespondToSelector:_cmd]) {
        [super rfcommChannelData:rfcommChannel data:dataPointer length:dataLength];
    }
}

@end
