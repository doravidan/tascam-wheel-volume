#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
typedef struct AudioBridge AudioBridge;
AudioBridge *bridge_create(void);
void bridge_free(AudioBridge *);
void bridge_gain(AudioBridge *, unsigned percent);
bool bridge_layout(AudioDeviceID device, bool input, double *rate);
OSStatus bridge_capture(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *,
 const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *);
OSStatus bridge_play(AudioDeviceID, const AudioTimeStamp *, const AudioBufferList *,
 const AudioTimeStamp *, AudioBufferList *, const AudioTimeStamp *, void *);
unsigned bridge_frames(AudioBridge *);
bool bridge_self_test(void);
OSStatus bridge_prepare_capture(AudioDeviceID, AudioBridge *, AudioDeviceIOProcID *);
OSStatus bridge_prepare_play(AudioDeviceID, AudioBridge *, AudioDeviceIOProcID *);
