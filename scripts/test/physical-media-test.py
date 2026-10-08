import sys
sys.dont_write_bytecode = True
import importlib.util
from pathlib import Path
import unittest
import tempfile
spec=importlib.util.spec_from_file_location('physical_media', Path(__file__).resolve().parents[1]/'qualify-physical-media.py')
media=importlib.util.module_from_spec(spec);spec.loader.exec_module(media)

def fixture():
    return {'streams':[{'codec_type':'video','codec_name':'h264','width':3840,'height':2160,'start_time':'0','duration':'10'},
                       {'codec_type':'audio','codec_name':'aac','sample_rate':'48000','start_time':'0','duration':'10'}],
            'frames':[{'media_type':'video','best_effort_timestamp_time':str(i/30)} for i in range(300)]+
                     [{'media_type':'audio','best_effort_timestamp_time':str(i/50),'nb_samples':960} for i in range(500)]}

class MediaTests(unittest.TestCase):
    def native_aac(self, *, discard=0):
        # The replacement phone's real AAC export has 452 encoded packets and
        # 2,112 explicitly skipped priming samples spanning three packets.
        d=fixture();d.pop('frames')
        d['streams'][0]['duration']='9.6'
        samples=452*1024-2112-discard
        d['streams'][1]['duration']=str(samples/48000)
        d['packets']=[{'codec_type':'video','pts_time':str(i/30),'duration_time':str(1/30)} for i in range(288)]+[
            {'codec_type':'audio','pts_time':str((i*1024-2112)/48000),'duration_time':str(1024/48000)} for i in range(452)]
        d['packets'][288]['side_data_list']=[{'side_data_type':'Skip Samples','skip_samples':2112,'discard_padding':0}]
        if discard:
            d['packets'][-1]['side_data_list']=[{'side_data_type':'Skip Samples','skip_samples':0,'discard_padding':discard}]
        return d, samples
    def test_native_aac_priming_matches_playable_samples_without_hiding_gaps(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'recording-export.mp4';path.write_bytes(b'x')
            d,samples=self.native_aac()
            report={'contract':'scorebug-native-export-v1','fullDecodeCompleted':True,
                    'fileName':path.name,'bytes':1,'recordingID':'recording','videoFrames':288,'audioSamples':samples}
            decoded=media.native_packets(d,report,path)
            audio=[f for f in decoded['frames'] if f['media_type']=='audio']
            self.assertEqual(sum(f['nb_samples'] for f in audio),samples)
            self.assertAlmostEqual(float(audio[0]['best_effort_timestamp_time']),0)
            self.assertTrue(all(media.media_gates(media.summarize_media(decoded),3840,2160,8).values()))
            d['packets'].pop(400);d['packets'].pop(400)
            with self.assertRaises(AssertionError):media.native_packets(d,report,path)
            d,_=self.native_aac()
            d['packets'][400]['pts_time']=str(float(d['packets'][400]['pts_time'])+.01)
            self.assertFalse(media.media_gates(media.summarize_media(media.native_packets(d,report,path)),3840,2160)['audioContinuity'])
    def test_native_aac_declared_tail_padding_is_trimmed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'recording-export.mp4';path.write_bytes(b'x')
            d,samples=self.native_aac(discard=64)
            report={'contract':'scorebug-native-export-v1','fullDecodeCompleted':True,
                    'fileName':path.name,'bytes':1,'recordingID':'recording','videoFrames':288,'audioSamples':samples}
            decoded=media.native_packets(d,report,path)
            self.assertEqual(sum(f['nb_samples'] for f in decoded['frames'] if f['media_type']=='audio'),samples)
            self.assertTrue(all(media.media_gates(media.summarize_media(decoded),3840,2160,8).values()))
    def test_complete_media_has_independent_gates(self):
        s=media.summarize_media(fixture());self.assertTrue(all(media.media_gates(s,3840,2160).values()))
        self.assertFalse(media.media_gates(s,1920,1080)['dimensions'])
        self.assertFalse(media.media_gates(s,3840,2160,600)['duration'])
    def test_missing_and_regressing_frames_are_rejected(self):
        d=fixture();d['frames']=[f for i,f in enumerate(d['frames']) if i%3 or f['media_type']=='audio']
        self.assertFalse(media.media_gates(media.summarize_media(d),3840,2160)['encodedCadence'])
        d=fixture();d['frames'][100]['best_effort_timestamp_time']='0'
        self.assertFalse(media.media_gates(media.summarize_media(d),3840,2160)['videoOrder'])
    def test_audio_gap_and_long_track_tail_are_rejected(self):
        d=fixture();d['frames'].pop(400)
        self.assertFalse(media.media_gates(media.summarize_media(d),3840,2160)['audioContinuity'])
        d=fixture();d['streams'][1]['duration']='10.2'
        self.assertFalse(media.media_gates(media.summarize_media(d),3840,2160)['trackEnds'])

if __name__=='__main__':unittest.main()
