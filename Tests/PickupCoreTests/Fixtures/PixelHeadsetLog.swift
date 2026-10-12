// Real transcript from the phase 0 headset run: MacBookPro18,1 / macOS 27.0.1 with a Pixel 9 Pro /
// Android 17 that also had a Bluetooth headset connected, 2026-10-11
// (`apple-hfp-20261011-112313.log`, recorded with a real Pixel). Phone numbers were already
// abbreviated by the spike; the Bluetooth address and the contact name in +CLIP are replaced.
//
// Unlike the run without a headset, the Pixel sends RING and +CLIP (with the contact name) right
// after +CIEV callsetup=1. One call: incoming 11:25:18, accepted on the Mac, hung up on the Mac.

enum PixelHeadsetLog {
    static let full = #"""
2026-10-11T11:23:13.611+02:00 [STATE   ] target name='Pixel 9 Pro' address=aa-bb-cc-dd-ee-ff connected=true hfpAG=true agSDPFeatures=0x012f
2026-10-11T11:23:13.613+02:00 [STATE   ] link idle -> connecting
2026-10-11T11:23:13.613+02:00 [CMD     ] connect() -> service level connection
2026-10-11T11:23:14.314+02:00 [AT      ] >> AT+BRSF=116    [writeAsync]
2026-10-11T11:23:14.413+02:00 [AT      ] << +BRSF: 879    [channel class IOBluetoothRFCOMMChannel, id 4]
2026-10-11T11:23:14.417+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.417+02:00 [AT      ] >> AT+CIND=?    [writeAsync]
2026-10-11T11:23:14.561+02:00 [AT      ] << +CIND: ("call",(0,1)),("callsetup",(0-3)),("service",(0-1)),("signal",(0-5)),("roam",(0,1)),("battchg",(0-5)),("callheld",(0-2))
2026-10-11T11:23:14.566+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.566+02:00 [AT      ] >> AT+CIND?    [writeAsync]
2026-10-11T11:23:14.684+02:00 [AT      ] << +CIND: 0,0,1,5,0,4,0
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator call=0
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator service=1
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator signal=5
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator roam=0
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator battchg=4
2026-10-11T11:23:14.686+02:00 [DELEGATE] indicator callheld=0
2026-10-11T11:23:14.691+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.691+02:00 [AT      ] >> AT+CMER=3,0,0,1    [writeAsync]
2026-10-11T11:23:14.703+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.703+02:00 [AT      ] >> AT+CHLD=?    [writeAsync]
2026-10-11T11:23:14.734+02:00 [AT      ] << +CHLD: (0,1,2,3)
2026-10-11T11:23:14.735+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.736+02:00 [AT      ] >> AT+CLIP=1    [writeAsync]
2026-10-11T11:23:14.742+02:00 [AT      ] << +BSIR: 0
2026-10-11T11:23:14.743+02:00 [DELEGATE] unhandledResultCode '+BSIR: 0'
2026-10-11T11:23:14.748+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.749+02:00 [AT      ] >> AT+CLCC    [writeAsync]
2026-10-11T11:23:14.782+02:00 [AT      ] << +BSIR: 1
2026-10-11T11:23:14.782+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:14.783+02:00 [DELEGATE] unhandledResultCode '+BSIR: 1'
2026-10-11T11:23:14.783+02:00 [AT      ] >> AT+CSMS=?    [writeAsync]
2026-10-11T11:23:14.816+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:23:14.816+02:00 [AT      ] >> AT+CSMS?    [writeAsync]
2026-10-11T11:23:14.862+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:23:14.862+02:00 [AT      ] >> AT+CMGF=?    [writeAsync]
2026-10-11T11:23:14.893+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:23:14.893+02:00 [AT      ] >> AT+CNMI=?    [writeAsync]
2026-10-11T11:23:14.946+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:23:14.946+02:00 [AT      ] >> AT+CNMI=3,1,0,0,0    [writeAsync]
2026-10-11T11:23:14.985+02:00 [AT      ] << ERROR    (error)
2026-10-11T11:23:14.985+02:00 [AT      ] >> AT+CSCS="UTF-8"    [writeAsync]
2026-10-11T11:23:15.017+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:15.017+02:00 [AT      ] >> AT+VGS=7    [writeAsync]
2026-10-11T11:23:15.084+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:15.084+02:00 [AT      ] >> AT+VGM=7    [writeAsync]
2026-10-11T11:23:15.117+02:00 [AT      ] << OK    (ok)
2026-10-11T11:23:15.117+02:00 [DELEGATE] connected status=0x00000000 (success)
2026-10-11T11:23:15.117+02:00 [STATE   ] link connecting -> connected
2026-10-11T11:23:30.710+02:00 [AT      ] << +CIEV: 4,4    (indicator(index: 4, value: 4))
2026-10-11T11:23:30.711+02:00 [DELEGATE] indicator signal=4
2026-10-11T11:24:19.594+02:00 [AT      ] << +BSIR: 0
2026-10-11T11:24:19.598+02:00 [DELEGATE] unhandledResultCode '+BSIR: 0'
2026-10-11T11:24:27.660+02:00 [AT      ] << +CIEV: 4,5    (indicator(index: 4, value: 5))
2026-10-11T11:24:27.660+02:00 [DELEGATE] indicator signal=5
2026-10-11T11:24:30.624+02:00 [AT      ] << +CIEV: 4,4    (indicator(index: 4, value: 4))
2026-10-11T11:24:30.624+02:00 [DELEGATE] indicator signal=4
2026-10-11T11:25:18.498+02:00 [AT      ] << +CIEV: 2,1    (indicator(index: 2, value: 1))
2026-10-11T11:25:18.500+02:00 [DELEGATE] indicator callsetup=1 (incoming)
2026-10-11T11:25:18.501+02:00 [AT      ] << RING    (ring)
2026-10-11T11:25:18.502+02:00 [AT      ] << +CLIP: "+49*******515",145,,,"Jane Doe"    (callerID(number: "+49*******515"))
2026-10-11T11:25:18.502+02:00 [DELEGATE] ringAttempt count=1
2026-10-11T11:25:18.502+02:00 [DELEGATE] incomingCallFrom number=+49*******515  -> type 'accept' or 'decline'
2026-10-11T11:25:22.782+02:00 [CMD     ] > accept
2026-10-11T11:25:22.783+02:00 [CMD     ] acceptCallOnPhone()
2026-10-11T11:25:22.783+02:00 [AT      ] >> ATA    [writeAsync]
2026-10-11T11:25:23.449+02:00 [AT      ] << OK    (ok)
2026-10-11T11:25:23.452+02:00 [AT      ] << +BSIR: 0
2026-10-11T11:25:23.452+02:00 [DELEGATE] unhandledResultCode '+BSIR: 0'
2026-10-11T11:25:23.466+02:00 [AT      ] << +CIEV: 1,1    (indicator(index: 1, value: 1))
2026-10-11T11:25:23.467+02:00 [AT      ] << +CIEV: 2,0    (indicator(index: 2, value: 0))
2026-10-11T11:25:23.467+02:00 [DELEGATE] indicator call=1
2026-10-11T11:25:23.467+02:00 [DELEGATE] indicator callsetup=0 (none)
2026-10-11T11:25:37.293+02:00 [AT      ] << +CIEV: 4,5    (indicator(index: 4, value: 5))
2026-10-11T11:25:37.294+02:00 [DELEGATE] indicator signal=5
2026-10-11T11:25:38.200+02:00 [CMD     ] > hangup
2026-10-11T11:25:38.207+02:00 [CMD     ] endCall()
2026-10-11T11:25:38.208+02:00 [AT      ] >> AT+CHUP    [writeAsync]
2026-10-11T11:25:38.792+02:00 [AT      ] << OK    (ok)
2026-10-11T11:25:39.774+02:00 [AT      ] << +CIEV: 1,0    (indicator(index: 1, value: 0))
2026-10-11T11:25:39.775+02:00 [DELEGATE] indicator call=0
2026-10-11T11:27:46.736+02:00 [CMD     ] > quit
2026-10-11T11:27:46.737+02:00 [CMD     ] disconnect before exit
2026-10-11T11:27:46.737+02:00 [STATE   ] link connected -> disconnecting
2026-10-11T11:27:46.737+02:00 [CMD     ] disconnect()
2026-10-11T11:27:47.474+02:00 [DELEGATE] disconnected status=0x00000000 (success)
2026-10-11T11:27:47.478+02:00 [STATE   ] link disconnecting -> idle
"""#
}
