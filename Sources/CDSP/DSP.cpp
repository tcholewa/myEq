// Biquad coefficient equations: Robert Bristow-Johnson's Audio EQ Cookbook,
// as published by W3C (2021). See THIRD_PARTY_NOTICES.md for attribution,
// adaptation details, and the W3C Software and Document License.
#include "CDSP.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstring>
#include <vector>

namespace {
static_assert(std::atomic<float>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free, "Audio telemetry must be lock-free");
constexpr int bandsCount = 8, queueSize = 16;
constexpr double pi = 3.14159265358979323846;
uint64_t packPeaks(float left, float right) {
    uint32_t l, r;
    std::memcpy(&l, &left, sizeof(l)); std::memcpy(&r, &right, sizeof(r));
    return (uint64_t(l) << 32) | r;
}
std::array<float, 2> unpackPeaks(uint64_t packed) {
    const uint32_t l = uint32_t(packed >> 32), r = uint32_t(packed);
    std::array<float, 2> values;
    std::memcpy(&values[0], &l, sizeof(l)); std::memcpy(&values[1], &r, sizeof(r));
    return values;
}
struct Coeff { double b0=1,b1=0,b2=0,a1=0,a2=0; };
struct State { double z1=0,z2=0; };
struct Config { std::array<Coeff,bandsCount> coeff; double gain=1; };
struct Bank {
    Config config;
    State state[2][bandsCount]{};
    double tick(double sample, int channel) {
        double x=sample*config.gain;
        for(int i=0;i<bandsCount;++i) {
            const auto &c=config.coeff[i]; auto &s=state[channel][i];
            const double y=c.b0*x+s.z1;
            s.z1=c.b1*x-c.a1*y+s.z2; s.z2=c.b2*x-c.a2*y; x=y;
        }
        return x;
    }
};
Coeff coefficients(const MEQBand &b,double fs) {
    if(!b.enabled) return {};
    const double f=std::clamp(b.frequency,20.0,std::min(20000.0,fs*.45));
    const double w=2*pi*f/fs, sn=sin(w), cs=cos(w);
    const double A=pow(10.,std::clamp(b.gain,-24.,24.)/40.);
    double alpha, b0,b1,b2,a0,a1,a2;
    switch(b.type) {
    case 0:
        alpha=sn*sinh(log(2.)/2*std::clamp(b.width,.05,5.)*w/sn);
        b0=1+alpha*A;b1=-2*cs;b2=1-alpha*A;a0=1+alpha/A;a1=-2*cs;a2=1-alpha/A;break;
    case 1: case 2: {
        alpha=sn/2*sqrt((A+1/A)*(1/std::clamp(b.width,.1,1.)-1)+2);
        const double t=2*sqrt(A)*alpha;
        if(b.type==1) {
            b0=A*((A+1)-(A-1)*cs+t); b1=2*A*((A-1)-(A+1)*cs); b2=A*((A+1)-(A-1)*cs-t);
            a0=(A+1)+(A-1)*cs+t;a1=-2*((A-1)+(A+1)*cs);a2=(A+1)+(A-1)*cs-t;
        } else {
            b0=A*((A+1)+(A-1)*cs+t); b1=-2*A*((A-1)+(A+1)*cs); b2=A*((A+1)+(A-1)*cs-t);
            a0=(A+1)-(A-1)*cs+t;a1=2*((A-1)-(A+1)*cs);a2=(A+1)-(A-1)*cs-t;
        }break;
    }
    case 3: case 4:
        alpha=sn/(2*std::clamp(b.width,.1,10.));
        if(b.type==3) {b0=(1+cs)/2;b1=-(1+cs);b2=b0;}
        else {b0=(1-cs)/2;b1=1-cs;b2=b0;}
        a0=1+alpha;a1=-2*cs;a2=1-alpha;break;
    default: return {};
    }
    return {b0/a0,b1/a0,b2/a0,a1/a0,a2/a0};
}
bool valid(const MEQBand *bands,int n,double preamp) {
    if(!bands || n<0 || n>8 || !std::isfinite(preamp) || preamp>12 || preamp < -240) return false;
    for(int i=0;i<n;++i) if(!std::isfinite(bands[i].frequency)||!std::isfinite(bands[i].gain)||!std::isfinite(bands[i].width)) return false;
    return true;
}
Config config(const MEQBand *bands,int n,double preamp,double rate) {
    Config c;c.gain=pow(10.,preamp/20.);
    for(int i=0;i<n;++i)c.coeff[i]=coefficients(bands[i],rate);
    return c;
}
}

struct MEQDSP {
    double rate=48000,release=0,limiterGain=1;
    Bank current,old;
    std::array<Config,queueSize> queue;
    std::atomic<unsigned> read{0},write{0};
    uint32_t fadeRemaining=0,fadeLength=960,delay=48;
    uint64_t sequence=0;
    size_t head=0,tail=0;
    std::vector<std::array<double,2>> delayLine;
    std::vector<double> maxima;
    std::vector<uint64_t> positions;
    MEQChannel inL{},inR{},outL{},outR{};
    std::atomic<uint64_t> peaks{0};
    std::atomic<float> reduction{0};
    // Odd epochs collect visual data. Each visibility transition starts a new
    // interval, including a hide/show pair entirely between audio callbacks.
    std::atomic<uint64_t> meterEpoch{0},publishedMeterEpoch{0};
    uint64_t callbackMeterEpoch=0;
    std::atomic<uint64_t> callbacks{0},faults{0};
    void publishLevels(float left, float right, double minGain) {
        // One packed atomic gives both channels the same polling interval.
        auto old = peaks.load(std::memory_order_relaxed);
        for (;;) {
            const auto previous = unpackPeaks(old);
            const auto next = packPeaks(std::max(left, previous[0]), std::max(right, previous[1]));
            if (peaks.compare_exchange_weak(old, next, std::memory_order_relaxed)) break;
        }
        const float attenuation = float(-20 * log10(std::max(minGain, 1e-20)));
        auto oldReduction = reduction.load(std::memory_order_relaxed);
        while (oldReduction < attenuation && !reduction.compare_exchange_weak(oldReduction, attenuation, std::memory_order_relaxed)) {}
    }
    template<bool Metering, typename Source, typename Destination>
    void render(uint32_t n, Source source, Destination dest, uint64_t epoch) {
        float peakLeft=0,peakRight=0;double minGain=1;
        for(uint32_t i=0;i<n;++i) {
            double l=source(0,i),r=source(1,i);
            frame(l,r);dest(0,i,l);dest(1,i,r);
            if constexpr(Metering) {
                peakLeft=std::max(peakLeft,float(std::abs(l)));
                peakRight=std::max(peakRight,float(std::abs(r)));
                minGain=std::min(minGain,limiterGain);
            }
        }
        if constexpr(Metering) {
            if(meterEpoch.load(std::memory_order_acquire)==epoch) {
                publishLevels(peakLeft,peakRight,minGain);
                publishedMeterEpoch.store(epoch,std::memory_order_release);
            }
        }
        callbacks.fetch_add(1,std::memory_order_relaxed);
    }
    template<typename Source, typename Destination>
    void process(uint32_t n, Source source, Destination dest) {
        begin();
        const auto epoch=meterEpoch.load(std::memory_order_acquire);
        if(epoch!=callbackMeterEpoch) {
            // Only the audio thread resets these between render blocks, so an
            // in-flight block can never leak an old peak into a new epoch.
            peaks.store(0,std::memory_order_relaxed);
            reduction.store(0,std::memory_order_relaxed);
            callbackMeterEpoch=epoch;
        }
        if(epoch&1) render<true>(n,source,dest,epoch);
        else render<false>(n,source,dest,epoch);
    }
    MEQMeter meter(bool consume) {
        MEQMeter result{0,0,0,callbacks.load(std::memory_order_relaxed),faults.load(std::memory_order_relaxed)};
        const auto epoch=meterEpoch.load(std::memory_order_acquire);
        if((epoch&1) && publishedMeterEpoch.load(std::memory_order_acquire)==epoch) {
            const auto p=unpackPeaks(consume ? peaks.exchange(0,std::memory_order_relaxed) : peaks.load(std::memory_order_relaxed));
            result.peakLeft=p[0];result.peakRight=p[1];
            result.reduction=consume ? reduction.exchange(0,std::memory_order_relaxed) : reduction.load(std::memory_order_relaxed);
        }
        return result;
    }
    void begin() {
        const unsigned r=read.load(std::memory_order_relaxed),w=write.load(std::memory_order_acquire);
        if(r!=w && !fadeRemaining) {
            old=current; current=Bank{}; current.config=queue[(w-1)%queueSize];
            read.store(w,std::memory_order_release); fadeRemaining=fadeLength;
        }
    }
    void frame(double &l,double &r) {
        if(!std::isfinite(l)||!std::isfinite(r)) {l=r=0;faults.fetch_add(1,std::memory_order_relaxed);}
        double a=current.tick(l,0),b=current.tick(r,1);
        if(fadeRemaining) {
            const double t=1-double(fadeRemaining)/fadeLength;
            a=old.tick(l,0)*(1-t)+a*t;b=old.tick(r,1)*(1-t)+b*t;--fadeRemaining;
        }
        if(!std::isfinite(a)||!std::isfinite(b)) {
            a=b=0;
            std::memset(current.state,0,sizeof(current.state));std::memset(old.state,0,sizeof(old.state));
            faults.fetch_add(1,std::memory_order_relaxed);
        }
        const size_t capacity=maxima.size();
        while(head!=tail && sequence>delay && positions[head]<sequence-delay) head=(head+1)%capacity;
        const double p=std::max(std::abs(a),std::abs(b));
        while(head!=tail && maxima[(tail+capacity-1)%capacity]<=p)tail=(tail+capacity-1)%capacity;
        maxima[tail]=p;positions[tail]=sequence;tail=(tail+1)%capacity;
        const double desired=std::min(1.,pow(10.,-.5/20.)/std::max(maxima[head],1e-30));
        limiterGain=std::min(desired,1-(1-limiterGain)*release);
        const size_t slot=sequence%delayLine.size();
        auto delayed=delayLine[slot];delayLine[slot]={a,b};
        l=delayed[0]*limiterGain;r=delayed[1]*limiterGain;++sequence;
    }
};

extern "C" {
MEQDSP *meq_create(){return new MEQDSP;}
void meq_destroy(MEQDSP *d){delete d;}
bool meq_prepare(MEQDSP *d,double fs,const MEQBand *b,int n,double gain) {
    if(!d || !std::isfinite(fs)||fs<32000||fs>192000||!valid(b,n,gain))return false;
    d->rate=fs;d->current=Bank{};d->current.config=config(b,n,gain,fs);d->old=d->current;
    d->read=0;d->write=0;d->fadeRemaining=0;d->fadeLength=uint32_t(fs*.02);
    d->delay=uint32_t(ceil(fs*.001));d->release=exp(-1/(fs*.05));d->limiterGain=1;
    d->delayLine.assign(d->delay,{0,0});d->maxima.assign(d->delay+2,0);d->positions.assign(d->delay+2,0);
    d->sequence=0;d->head=d->tail=0;d->peaks=0;d->reduction=0;d->publishedMeterEpoch=0;d->callbackMeterEpoch=0;d->callbacks=0;d->faults=0;return true;
}
bool meq_submit(MEQDSP *d,const MEQBand *b,int n,double gain) {
    if(!d||!valid(b,n,gain))return false;
    const unsigned w=d->write.load(std::memory_order_relaxed),r=d->read.load(std::memory_order_acquire);
    if(w-r>=queueSize)return false;
    d->queue[w%queueSize]=config(b,n,gain,d->rate);d->write.store(w+1,std::memory_order_release);return true;
}
void meq_layout(MEQDSP*d,MEQChannel a,MEQChannel b,MEQChannel c,MEQChannel e){d->inL=a;d->inR=b;d->outL=c;d->outR=e;}
void meq_process(MEQDSP*d,float*s,uint32_t n) {
    if(!d||d->delayLine.empty())return;
    d->process(n,[s](int c,uint32_t i){return s[i*2+c];},[s](int c,uint32_t i,double v){s[i*2+c]=float(v);});
}
void meq_set_metering_enabled(MEQDSP*d,bool enabled) {
    const auto epoch=d->meterEpoch.load(std::memory_order_relaxed);
    if(bool(epoch&1)!=enabled)d->meterEpoch.store(epoch+1,std::memory_order_release);
}
MEQMeter meq_meter(MEQDSP*d){return d->meter(false);}
MEQMeter meq_take_meter(MEQDSP*d){return d->meter(true);}
double meq_response(const MEQBand*b,int n,double f,double fs) {
    if(!valid(b,n,0)||!std::isfinite(f)||!std::isfinite(fs)||fs<32000)return 0;
    const auto z=std::polar(1.,-2*pi*f/fs);double db=0;
    for(int i=0;i<n;++i){auto c=coefficients(b[i],fs);auto h=(c.b0+c.b1*z+c.b2*z*z)/(1.+c.a1*z+c.a2*z*z);db+=20*log10(std::max(std::abs(h),1e-15));}return db;
}
OSStatus meq_audio_callback(AudioObjectID,const AudioTimeStamp*,const AudioBufferList*in,const AudioTimeStamp*,AudioBufferList*out,const AudioTimeStamp*,void*context) {
    auto*d=static_cast<MEQDSP*>(context);
    for(UInt32 i=0;i<out->mNumberBuffers;++i)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);
    auto layoutValid=[](const AudioBufferList*list,MEQChannel c) {
        return c.buffer>=0 && uint32_t(c.buffer)<list->mNumberBuffers && c.stride>0 && c.channel>=0 && c.channel<c.stride && list->mBuffers[c.buffer].mNumberChannels==uint32_t(c.stride);
    };
    if(!layoutValid(in,d->inL)||!layoutValid(in,d->inR)) {
        d->faults.fetch_add(1,std::memory_order_relaxed);d->callbacks.fetch_add(1,std::memory_order_relaxed);return noErr;
    }
    auto available=[](const AudioBufferList*list,MEQChannel c)->uint32_t {
        if(c.buffer<0||uint32_t(c.buffer)>=list->mNumberBuffers||c.stride<=0)return 0;
        const auto&b=list->mBuffers[c.buffer];if(!b.mData||c.channel<0||c.channel>=c.stride||b.mNumberChannels!=uint32_t(c.stride))return 0;
        return b.mDataByteSize/(sizeof(float)*c.stride);
    };
    const auto inputL=available(in,d->inL),inputR=available(in,d->inR);
    auto n=std::min(available(out,d->outL),available(out,d->outR));
    if(!n){d->faults.fetch_add(1,std::memory_order_relaxed);d->callbacks.fetch_add(1,std::memory_order_relaxed);return noErr;}
    // A dormant tap may supply null input buffers. Render silence and keep the
    // physical output clock running; absence of signal is not a callback failure.
    auto source=[in](MEQChannel c,uint32_t i,uint32_t frames){return i<frames ? static_cast<const float*>(in->mBuffers[c.buffer].mData)[i*c.stride+c.channel] : 0.f;};
    auto dest=[out](MEQChannel c,uint32_t i,double v){static_cast<float*>(out->mBuffers[c.buffer].mData)[i*c.stride+c.channel]=float(v);};
    d->process(n,[&](int c,uint32_t i){return c ? source(d->inR,i,inputR) : source(d->inL,i,inputL);},
                 [&](int c,uint32_t i,double v){dest(c ? d->outR : d->outL,i,v);});
    return noErr;
}
}
