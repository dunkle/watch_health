"""Exercise the actual AudioCapture transcribe orchestration with platform stand-ins.

Runs after scripts/check.sh builds WatchMindCore, using SWIFT_BIN for the same compiler.
Only the actual transcribe/cancellation methods are extracted; Speech, AVAsset export,
energy and recording I/O are controlled doubles. This is not an Apple SDK or ASR test.
No recordings, keys, public model calls or previously created /tmp files are used.
"""
from pathlib import Path
import subprocess
import tempfile
import os

root = Path(__file__).resolve().parents[2]
swift = os.environ.get('SWIFT_BIN', 'swift')
swiftc = str(Path(swift).with_name('swiftc')) if '/' in swift else 'swiftc'
environment = dict(os.environ, CLANG_MODULE_CACHE_PATH='/tmp/watchmind-transcription-check-clang')
build = Path(subprocess.check_output([swift, 'build', '--show-bin-path'], cwd=root, env=environment, text=True).strip())
objects = sorted((build / 'WatchMindCore.build').glob('*.swift.o'))
assert objects, 'Build the core with scripts/check.sh first.'
s=(root/'iOS/AudioCapture.swift').read_text();method=s[s.index('    func cancelTranscription()'):s.index('    private func export(asset:')]
intro=r'''
import Foundation
import WatchMindCore
struct StubTime { var seconds: Double }
enum StubKey { case duration }
final class AVURLAsset { let url:URL; init(url:URL) {self.url=url}; func load(_ key:StubKey) async throws -> StubTime { .init(seconds:100) } }
final class SFSpeechRecognizer { init?(locale:Locale) {}; var isAvailable=true; var supportsOnDeviceRecognition=true }
final class StubRecorder {}
final class StubExport { func cancelExport() {} }
enum AudioQuality { static func analyze(url:URL,sensitivity:Int)->AudioQualitySummary? { nil } }
@MainActor final class ProbeCapture {
    struct TranscriptionResult { var text:String;var segments:[TranscriptSegment];var failedChunks:Int;var duration:Double;var spans:[(Range<Double>,ProcessingSpan.Outcome)] }
    enum CaptureError:Error { case busy, unavailable, recording }
    private var recorder:StubRecorder?
    private var transcriptionSlot=OperationSlot()
    private var cancelledTranscription:UUID?
    private var exportSession:StubExport?
    private var speechSlot=OperationSlot()
    private var speechCompletion:((Result<(String,[TranscriptSegment]),Error>)->Void)?
    var calls=0
    var outcomes:[Bool]=[true,false,true]
'''
outro=r'''
    private func export(asset:AVURLAsset,range:Range<Double>,to:URL) async throws {}
    private func recognize(url:URL,language:AppLanguage) async throws -> (String,[TranscriptSegment]) {
        let index=calls;calls+=1
        let id=speechSlot.begin()!
        return try await withCheckedThrowingContinuation { c in
            speechCompletion={c.resume(with:$0)}
            Task { @MainActor in
                try? await Task.sleep(for:.milliseconds(20))
                guard speechSlot.owns(id) else{return}
                completeSpeech(id,outcomes[min(index,outcomes.count-1)] ? .success(("word\(index)",[.init(text:"word\(index)",offset:1,duration:1)])) : .failure(CaptureError.unavailable))
            }
        }
    }
    private func completeSpeech(_ id:UUID,_ result:Result<(String,[TranscriptSegment]),Error>) {
        guard speechSlot.owns(id),let c=speechCompletion else{return}
        speechSlot.finish(id);speechCompletion=nil;c(result)
    }
}
@main struct Harness {
    enum Stop:Error {case disk}
    @MainActor static func main() async throws {
        let url=URL(fileURLWithPath:"/tmp/probe-original.m4a")
        do {
            let p=ProbeCapture();var snapshots:[ProbeCapture.TranscriptionResult]=[]
            let r=try await p.transcribe(url:url,language:.english,checkpoint:{snapshots.append($0)},progress:{_,_ in})
            precondition(snapshots.count==3 && snapshots[0].spans.count==1 && snapshots[1].spans.count==2 && r.failedChunks==1 && r.text.contains("word0") && r.text.contains("word2"))
            print("PASS checkpoint after each successful or failed chunk")
        }
        do {
            let p=ProbeCapture()
            do {_ = try await p.transcribe(url:url,language:.english,checkpoint:{_ in throw Stop.disk},progress:{_,_ in});preconditionFailure()}
            catch Stop.disk {precondition(p.calls==1)}
            print("PASS disk checkpoint failure aborts before further recognition")
        }
        do {
            let p=ProbeCapture();var snapshots=0
            do {_ = try await p.transcribe(url:url,language:.english,checkpoint:{_ in snapshots+=1;p.cancelTranscription()},progress:{_,_ in});preconditionFailure()}
            catch is CancellationError {precondition(p.calls==1 && snapshots==1)}
            print("PASS explicit cancellation keeps delivered checkpoint and skips further work")
        }
        do {
            let p=ProbeCapture();var snapshots=0
            let task = Task { @MainActor in try await p.transcribe(url:url,language:.english,checkpoint:{_ in snapshots+=1},progress:{_,_ in}) }
            while p.calls==0 { await Task.yield() }
            task.cancel()
            do { _ = try await task.value; preconditionFailure() }
            catch is CancellationError { precondition(p.calls==1 && snapshots==0) }
            print("PASS parent task cancellation interrupts in-flight recognition once")
        }
        do {
            let p=ProbeCapture();p.outcomes=[true,true]
            let resume=ProbeCapture.TranscriptionResult(text:"saved",segments:[.init(text:"saved",offset:2,duration:1)],failedChunks:0,duration:100,spans:[(0..<45,.recognized)])
            let r=try await p.transcribe(url:url,language:.english,resuming:resume,progress:{_,_ in})
            precondition(p.calls==2 && r.segments.map(\.offset)==[2,46,91] && r.text.contains("saved"))
            print("PASS resume skips known success and retains correct file offsets")
        }
        do {
            let p=ProbeCapture();p.outcomes=[true,true,true]
            let legacy=ProbeCapture.TranscriptionResult(text:"old unaligned transcript",segments:[],failedChunks:0,duration:100,spans:[(0..<45,.recognized)])
            var snapshots:[ProbeCapture.TranscriptionResult]=[]
            let r=try await p.transcribe(url:url,language:.english,resuming:legacy,checkpoint:{snapshots.append($0)},progress:{_,_ in})
            precondition(p.calls==3 && r.segments.map(\.offset)==[1,46,91])
            precondition(!r.text.contains("old unaligned transcript") && r.text.contains("word0") && r.text.contains("word2"))
            precondition(snapshots[0].text==legacy.text && snapshots[0].segments.isEmpty, "A partial legacy retry must not invent time alignment")
            print("PASS unaligned legacy completion spans cannot skip fresh recognition or fake aligned words")
        }
        print("6 actual transcription orchestration stand-in scenarios passed; Apple APIs are not validated.")
    }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'Probe.swift').write_text(intro+method+outro)
 subprocess.run([swiftc,'-parse-as-library','-swift-version','5','-module-cache-path',str(p/'cache'),'-I',str(build/'Modules'),str(p/'Probe.swift'),*map(str, objects),'-o',str(p/'probe')],cwd=root,env=environment,check=True,timeout=90)
 subprocess.run([str(p/'probe')],cwd=root,env=environment,check=True,timeout=15)
