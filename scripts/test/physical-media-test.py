import sys
sys.dont_write_bytecode = True
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('physical_media', Path(__file__).resolve().parents[1]/'qualify-physical-media.py')
media=importlib.util.module_from_spec(spec);spec.loader.exec_module(media)

def fixture():
    return {'streams':[{'codec_type':'video','codec_name':'h264','width':3840,'height':2160,'start_time':'0','duration':'10'},
                       {'codec_type':'audio','codec_name':'aac','sample_rate':'48000','start_time':'0','duration':'10'}],
            'frames':[{'media_type':'video','best_effort_timestamp_time':str(i/30)} for i in range(300)]+
                     [{'media_type':'audio','best_effort_timestamp_time':str(i/50),'nb_samples':960} for i in range(500)]}

class MediaTests(unittest.TestCase):
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
