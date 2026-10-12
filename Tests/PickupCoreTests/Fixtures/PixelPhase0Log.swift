// Real transcript from the phase 0 spike: MacBookPro18,1 / macOS 27.0.1 with a Pixel 9 Pro /
// Android 17, 2026-10-11 (`apple-hfp-20261011-110815.log`, recorded with a real Pixel).
// Phone numbers were already abbreviated by the spike; the Bluetooth address is replaced.
// Spike-only noise (help/status output, feature dumps) is removed; AT, DELEGATE, CMD and link
// lines are verbatim.
//
// Calls in this log:
//  1. 11:08:46 incoming, not answered            -> missed
//  2. 11:11:58 incoming, accepted on the Mac      -> ended by the remote party at 11:12:15
//  3. 11:14:06 incoming, accepted, hung up on Mac -> hungUp at 11:14:22
//  4. 11:15:46 incoming, CLCC, declined on Mac    -> declined (number known)
//  5. 11:16:47 incoming, accepted, DTMF           -> ended by the remote party at 11:17:07
//  6. 11:18:43 outgoing, callsetup 2 -> 3 -> call=1, hung up on Mac -> hungUp at 11:19:03

enum PixelPhase0Log {
    static let full = #"""
2026-10-11T11:08:15.281+02:00 [STATE   ] target name='Pixel 9 Pro' address=aa-bb-cc-dd-ee-ff connected=true hfpAG=true agSDPFeatures=0x012f
2026-10-11T11:08:15.285+02:00 [STATE   ] link idle -> connecting
2026-10-11T11:08:15.285+02:00 [CMD     ] connect() -> service level connection
2026-10-11T11:08:15.571+02:00 [AT      ] >> AT+BRSF=116    [writeAsync]
2026-10-11T11:08:15.587+02:00 [AT      ] << +BRSF: 879    [channel class IOBluetoothRFCOMMChannel, id 4]
2026-10-11T11:08:15.591+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.591+02:00 [AT      ] >> AT+CIND=?    [writeAsync]
2026-10-11T11:08:15.627+02:00 [AT      ] << +CIND: ("call",(0,1)),("callsetup",(0-3)),("service",(0-1)),("signal",(0-5)),("roam",(0,1)),("battchg",(0-5)),("callheld",(0-2))
2026-10-11T11:08:15.631+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.632+02:00 [AT      ] >> AT+CIND?    [writeAsync]
2026-10-11T11:08:15.665+02:00 [AT      ] << +CIND: 0,0,1,5,0,4,0
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator call=0
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator service=1
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator signal=5
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator roam=0
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator battchg=4
2026-10-11T11:08:15.665+02:00 [DELEGATE] indicator callheld=0
2026-10-11T11:08:15.665+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.665+02:00 [AT      ] >> AT+CMER=3,0,0,1    [writeAsync]
2026-10-11T11:08:15.697+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.697+02:00 [AT      ] >> AT+CHLD=?    [writeAsync]
2026-10-11T11:08:15.699+02:00 [AT      ] << +BSIR: 0
2026-10-11T11:08:15.699+02:00 [DELEGATE] unhandledResultCode '+BSIR: 0'
2026-10-11T11:08:15.700+02:00 [AT      ] << +BSIR: 1
2026-10-11T11:08:15.701+02:00 [DELEGATE] unhandledResultCode '+BSIR: 1'
2026-10-11T11:08:15.773+02:00 [AT      ] << +CHLD: (0,1,2,3)
2026-10-11T11:08:15.774+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.774+02:00 [AT      ] >> AT+CLIP=1    [writeAsync]
2026-10-11T11:08:15.810+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.810+02:00 [AT      ] >> AT+CLCC    [writeAsync]
2026-10-11T11:08:15.854+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:15.854+02:00 [AT      ] >> AT+CSMS=?    [writeAsync]
2026-10-11T11:08:15.994+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:08:15.996+02:00 [AT      ] >> AT+CSMS?    [writeAsync]
2026-10-11T11:08:16.106+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:08:16.107+02:00 [AT      ] >> AT+CMGF=?    [writeAsync]
2026-10-11T11:08:16.148+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:08:16.149+02:00 [AT      ] >> AT+CNMI=?    [writeAsync]
2026-10-11T11:08:16.183+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:08:16.184+02:00 [AT      ] >> AT+CNMI=3,1,0,0,0    [writeAsync]
2026-10-11T11:08:16.219+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:08:16.219+02:00 [AT      ] >> AT+CSCS="UTF-8"    [writeAsync]
2026-10-11T11:08:16.263+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:16.264+02:00 [DELEGATE] connected status=0x00000000 (success)
2026-10-11T11:08:16.264+02:00 [STATE   ] link connecting -> connected
2026-10-11T11:08:24.336+02:00 [AT      ] >> AT+VGS=7    [writeAsync]
2026-10-11T11:08:24.979+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:24.980+02:00 [AT      ] >> AT+VGM=7    [writeAsync]
2026-10-11T11:08:25.076+02:00 [AT      ] << OK    (ok)
2026-10-11T11:08:46.688+02:00 [AT      ] << +CIEV: 2,1    (indicator(index: 2, value: 1))
2026-10-11T11:08:46.691+02:00 [DELEGATE] indicator callsetup=1 (incoming)
2026-10-11T11:09:10.916+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:09:10.917+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:11:58.227+02:00 [AT      ] << +CIEV: 2,1    (indicator(index: 2, value: 1))
2026-10-11T11:11:58.233+02:00 [DELEGATE] indicator callsetup=1 (incoming)
2026-10-11T11:12:03.416+02:00 [CMD     ] > accept
2026-10-11T11:12:03.416+02:00 [CMD     ] acceptCallOnPhone()
2026-10-11T11:12:03.416+02:00 [AT      ] >> ATA    [writeAsync]
2026-10-11T11:12:03.513+02:00 [AT      ] << OK    (ok)
2026-10-11T11:12:03.608+02:00 [AT      ] << +CIEV: 1,1    (indicator(index: 1, value: 1))
2026-10-11T11:12:03.610+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:12:03.612+02:00 [DELEGATE] indicator call=1
2026-10-11T11:12:03.613+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:12:12.286+02:00 [AT      ] << +CIEV: 4,4    (indicator(index: 4, value: 4))
2026-10-11T11:12:12.287+02:00 [DELEGATE] indicator signal=4
2026-10-11T11:12:15.255+02:00 [AT      ] << +CIEV: 1,0    (indicator(index: 1, value: 0))
2026-10-11T11:12:15.258+02:00 [DELEGATE] indicator call=0
2026-10-11T11:12:20.205+02:00 [AT      ] << +CIEV: 4,5    (indicator(index: 4, value: 5))
2026-10-11T11:12:20.206+02:00 [DELEGATE] indicator signal=5
2026-10-11T11:14:06.635+02:00 [AT      ] << +CIEV: 2,1    (indicator(index: 2, value: 1))
2026-10-11T11:14:06.639+02:00 [DELEGATE] indicator callsetup=1 (incoming)
2026-10-11T11:14:09.503+02:00 [CMD     ] > accpet
2026-10-11T11:14:09.503+02:00 [ERROR   ] unknown command 'accpet'; type 'help'
2026-10-11T11:14:12.866+02:00 [CMD     ] > accept
2026-10-11T11:14:12.866+02:00 [CMD     ] acceptCallOnPhone()
2026-10-11T11:14:12.866+02:00 [AT      ] >> ATA    [writeAsync]
2026-10-11T11:14:13.039+02:00 [AT      ] << OK    (ok)
2026-10-11T11:14:13.098+02:00 [AT      ] << +CIEV: 1,1    (indicator(index: 1, value: 1))
2026-10-11T11:14:13.098+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:14:13.099+02:00 [DELEGATE] indicator call=1
2026-10-11T11:14:13.099+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:14:20.422+02:00 [CMD     ] > hangup
2026-10-11T11:14:20.422+02:00 [CMD     ] endCall()
2026-10-11T11:14:20.422+02:00 [AT      ] >> AT+CHUP    [writeAsync]
2026-10-11T11:14:21.141+02:00 [AT      ] << OK    (ok)
2026-10-11T11:14:22.208+02:00 [AT      ] << +CIEV: 1,0    (indicator(index: 1, value: 0))
2026-10-11T11:14:22.209+02:00 [DELEGATE] indicator call=0
2026-10-11T11:15:46.753+02:00 [AT      ] << +CIEV: 2,1    (indicator(index: 2, value: 1))
2026-10-11T11:15:46.756+02:00 [DELEGATE] indicator callsetup=1 (incoming)
2026-10-11T11:15:50.618+02:00 [CMD     ] > clcc
2026-10-11T11:15:50.618+02:00 [CMD     ] currentCallList()
2026-10-11T11:15:50.618+02:00 [AT      ] >> AT+CLCC    [writeAsync]
2026-10-11T11:15:50.650+02:00 [AT      ] << +CLCC: 1,1,4,0,0,"+49*******515",145
2026-10-11T11:15:50.650+02:00 [AT      ] << OK    (ok)
2026-10-11T11:15:50.651+02:00 [DELEGATE] currentCall direction=1 index=1 mode=0 mulitiparty=0 number=+49*******515 status=4 type=145
2026-10-11T11:16:01.535+02:00 [CMD     ] > hangup
2026-10-11T11:16:01.535+02:00 [CMD     ] endCall()
2026-10-11T11:16:01.535+02:00 [AT      ] >> AT+CHUP    [writeAsync]
2026-10-11T11:16:02.475+02:00 [AT      ] << OK    (ok)
2026-10-11T11:16:02.481+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:16:02.481+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:16:47.778+02:00 [AT      ] << +CIEV: 2,1    (indicator(index: 2, value: 1))
2026-10-11T11:16:47.779+02:00 [DELEGATE] indicator callsetup=1 (incoming)
2026-10-11T11:16:52.133+02:00 [CMD     ] > accept
2026-10-11T11:16:52.133+02:00 [CMD     ] acceptCallOnPhone()
2026-10-11T11:16:52.133+02:00 [AT      ] >> ATA    [writeAsync]
2026-10-11T11:16:52.172+02:00 [AT      ] << OK    (ok)
2026-10-11T11:16:52.205+02:00 [AT      ] << +CIEV: 1,1    (indicator(index: 1, value: 1))
2026-10-11T11:16:52.206+02:00 [DELEGATE] indicator call=1
2026-10-11T11:16:52.206+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:16:52.206+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:16:54.294+02:00 [CMD     ] > dtmf 1
2026-10-11T11:16:54.296+02:00 [CMD     ] sendDTMF(1)
2026-10-11T11:16:54.296+02:00 [AT      ] >> AT+VTS=1    [writeAsync]
2026-10-11T11:16:54.404+02:00 [AT      ] << OK    (ok)
2026-10-11T11:17:07.252+02:00 [AT      ] << +CIEV: 1,0    (indicator(index: 1, value: 0))
2026-10-11T11:17:07.252+02:00 [DELEGATE] indicator call=0
2026-10-11T11:18:43.942+02:00 [CMD     ] > dial +49*******515
2026-10-11T11:18:43.945+02:00 [CMD     ] dialNumber(+49*******515)
2026-10-11T11:18:43.946+02:00 [AT      ] >> ATD+49*******515;    [writeAsync]
2026-10-11T11:18:45.268+02:00 [AT      ] << OK    (ok)
2026-10-11T11:18:45.272+02:00 [AT      ] << +CIEV: 2,2    (indicator(index: 2, value: 2))
2026-10-11T11:18:45.272+02:00 [AT      ] << +CIEV: 2,3    (indicator(index: 2, value: 3))
2026-10-11T11:18:45.272+02:00 [DELEGATE] indicator callsetup=2 (outgoing (dialing))
2026-10-11T11:18:45.272+02:00 [DELEGATE] indicator callsetup=3 (outgoing (remote alerted))
2026-10-11T11:18:54.523+02:00 [AT      ] << +CIEV: 1,1    (indicator(index: 1, value: 1))
2026-10-11T11:18:54.523+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:18:54.523+02:00 [DELEGATE] indicator call=1
2026-10-11T11:18:54.523+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:18:57.987+02:00 [AT      ] << +CIEV: 4,4    (indicator(index: 4, value: 4))
2026-10-11T11:18:57.988+02:00 [DELEGATE] indicator signal=4
2026-10-11T11:19:01.240+02:00 [CMD     ] > hangup
2026-10-11T11:19:01.240+02:00 [CMD     ] endCall()
2026-10-11T11:19:01.240+02:00 [AT      ] >> AT+CHUP    [writeAsync]
2026-10-11T11:19:01.947+02:00 [AT      ] << OK    (ok)
2026-10-11T11:19:03.048+02:00 [AT      ] << +CIEV: 1,0    (indicator(index: 1, value: 0))
2026-10-11T11:19:03.048+02:00 [DELEGATE] indicator call=0
2026-10-11T11:19:05.532+02:00 [AT      ] << +CIEV: 4,5    (indicator(index: 4, value: 5))
2026-10-11T11:19:05.532+02:00 [DELEGATE] indicator signal=5
2026-10-11T11:19:40.074+02:00 [CMD     ] > quit
2026-10-11T11:19:40.074+02:00 [CMD     ] disconnect before exit
2026-10-11T11:19:40.074+02:00 [STATE   ] link connected -> disconnecting
2026-10-11T11:19:40.074+02:00 [CMD     ] disconnect()
2026-10-11T11:19:41.402+02:00 [DELEGATE] disconnected status=0x00000000 (success)
2026-10-11T11:19:41.402+02:00 [STATE   ] link disconnecting -> idle
"""#
}
