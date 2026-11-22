#include "AudioBridge.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define CAP 32768u
struct AudioBridge {
    _Atomic unsigned write, read, gain, frames;
    float stereo[CAP][2];
};
AudioBridge *bridge_create(void) {
    AudioBridge *b = calloc(1, sizeof *b);
    if (b) { atomic_init(&b->write, 0); atomic_init(&b->read, 0); atomic_init(&b->frames, 0); atomic_init(&b->gain, 35); }
    return b;
}
void bridge_free(AudioBridge *b) { free(b); }
void bridge_gain(AudioBridge *b, unsigned v) { atomic_store(&b->gain, v > 100 ? 100 : v); }
unsigned bridge_frames(AudioBridge *b) { return atomic_load(&b->frames); }

// Only accept native float stereo (one interleaved or two mono buffers).
static unsigned count(const AudioBufferList *l) {
    if (!l) return 0;
    if (l->mNumberBuffers == 1 && l->mBuffers[0].mNumberChannels == 2 && l->mBuffers[0].mData)
        return l->mBuffers[0].mDataByteSize / (2 * sizeof(float));
    if (l->mNumberBuffers == 2 && l->mBuffers[0].mNumberChannels == 1 && l->mBuffers[1].mNumberChannels == 1
        && l->mBuffers[0].mData && l->mBuffers[1].mData && l->mBuffers[0].mDataByteSize == l->mBuffers[1].mDataByteSize)
        return l->mBuffers[0].mDataByteSize / sizeof(float);
    return 0;
}
static float sample(const AudioBufferList *l, unsigned i, unsigned c) {
    return l->mNumberBuffers == 1 ? ((const float *)l->mBuffers[0].mData)[2*i+c] : ((const float *)l->mBuffers[c].mData)[i];
}
static void put(AudioBufferList *l, unsigned i, unsigned c, float x) {
    if (l->mNumberBuffers == 1) ((float *)l->mBuffers[0].mData)[2*i+c] = x;
    else ((float *)l->mBuffers[c].mData)[i] = x;
}
static void capture(AudioBridge *b, const AudioBufferList *in) {
    unsigned n = count(in), w = atomic_load_explicit(&b->write, memory_order_relaxed);
    unsigned freeFrames = CAP - (w - atomic_load_explicit(&b->read, memory_order_acquire));
    if (n > freeFrames) n = freeFrames;
    for (unsigned i=0; i<n; i++) for (unsigned c=0; c<2; c++) b->stereo[(w+i)&(CAP-1)][c] = sample(in,i,c);
    atomic_store_explicit(&b->write,w+n,memory_order_release);
    atomic_fetch_add_explicit(&b->frames,n,memory_order_relaxed);
}
static void play(AudioBridge *b, AudioBufferList *out) {
    if (!out) return;
    unsigned n = count(out);
    if (!n) {
        for (unsigned i=0; i<out->mNumberBuffers; ++i)
            if (out->mBuffers[i].mData) memset(out->mBuffers[i].mData, 0, out->mBuffers[i].mDataByteSize);
        return;
    }
    unsigned r = atomic_load_explicit(&b->read,memory_order_relaxed);
    unsigned available = atomic_load_explicit(&b->write,memory_order_acquire)-r;
    // Discard stale backlog rather than allowing unbounded monitoring latency.
    if (available > n*8 && available > 4096) { r += available-n*2; available=n*2; }
    unsigned take = available < n ? available : n;
    float gain=(float)atomic_load_explicit(&b->gain,memory_order_relaxed)/100.0f;
    gain *= gain;
    for (unsigned i=0;i<n;i++) for (unsigned c=0;c<2;c++)
        put(out,i,c,i<take?b->stereo[(r+i)&(CAP-1)][c]*gain:0.0f);
    atomic_store_explicit(&b->read,r+take,memory_order_release);
}
OSStatus bridge_capture(AudioDeviceID d,const AudioTimeStamp *n,const AudioBufferList *in,const AudioTimeStamp *it,AudioBufferList *out,const AudioTimeStamp *ot,void *b) { capture(b,in); return noErr; }
OSStatus bridge_play(AudioDeviceID d,const AudioTimeStamp *n,const AudioBufferList *in,const AudioTimeStamp *it,AudioBufferList *out,const AudioTimeStamp *ot,void *b) { play(b,out); return noErr; }

bool bridge_layout(AudioDeviceID device, bool input, double *rate) {
    AudioObjectPropertyAddress p = {kAudioDevicePropertyStreams,
        input?kAudioDevicePropertyScopeInput:kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};
    UInt32 n = 0;
    if (AudioObjectGetPropertyDataSize(device,&p,0,NULL,&n) || n==0 || n>2*sizeof(AudioStreamID)) return false;
    AudioStreamID streams[2]={0}; if (AudioObjectGetPropertyData(device,&p,0,NULL,&n,streams)) return false;
    unsigned count=n/sizeof(AudioStreamID), channels=0; double sr=0;
    for (unsigned i=0;i<count;i++) {
        AudioObjectPropertyAddress q={kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioStreamBasicDescription f={0}; UInt32 len=sizeof(f);
        if (AudioObjectGetPropertyData(streams[i],&q,0,NULL,&len,&f) || f.mFormatID!=kAudioFormatLinearPCM ||
            !(f.mFormatFlags&kAudioFormatFlagIsFloat) || (f.mFormatFlags&kAudioFormatFlagIsBigEndian) ||
            f.mBitsPerChannel!=32 || f.mSampleRate<=0 || (i && sr!=f.mSampleRate)) return false;
        if (count==2 && f.mChannelsPerFrame!=1) return false;
        channels+=f.mChannelsPerFrame; sr=f.mSampleRate;
    }
    if (channels!=2) return false;
    *rate=sr; return true;
}
bool bridge_self_test(void) {
    AudioBridge *b=bridge_create(); if (!b) return false;
    float src[]={0.8f,-0.4f,0.2f,-0.1f}, dst[8]={0};
    AudioBufferList in={1,{{2,sizeof(src),src}}}, out={1,{{2,sizeof(dst),dst}}};
    bridge_gain(b,50); capture(b,&in); play(b,&out);
    bool good=fabsf(dst[0]-0.2f)<0.00001f && fabsf(dst[1]+0.1f)<0.00001f && fabsf(dst[2]-0.05f)<0.00001f && dst[4]==0 && bridge_frames(b)==2;
    bridge_gain(b,0); capture(b,&in); play(b,&out); good=good && dst[0]==0 && dst[1]==0;
    bridge_gain(b,150); capture(b,&in); play(b,&out); good=good && fabsf(dst[0]-src[0])<0.00001f;
    bridge_free(b); return good;
}
OSStatus bridge_prepare_capture(AudioDeviceID d, AudioBridge *b, AudioDeviceIOProcID *id) {
    return AudioDeviceCreateIOProcID(d, bridge_capture, b, id);
}
OSStatus bridge_prepare_play(AudioDeviceID d, AudioBridge *b, AudioDeviceIOProcID *id) {
    return AudioDeviceCreateIOProcID(d, bridge_play, b, id);
}
