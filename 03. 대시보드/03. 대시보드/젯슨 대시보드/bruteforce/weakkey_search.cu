// SPDX-License-Identifier: MIT
/* Exhaustive N-bit seed search with full AES-256-GCM tag verification. */

#include <cuda_runtime.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#define HD __host__ __device__
#define RECORD_MAGIC "ZYBOGCM1"
#define RECORD_VERSION 1U
#define CIPHERTEXT_BYTES 1440U
#define NO_SEED 0xffffffffU
#define MAX_CROSS_CHECK 4096U

static volatile sig_atomic_t stop_requested = 0;

static void on_signal(int) { stop_requested = 1; }

struct RecordFile {
    char magic[8];
    uint32_t version;
    uint32_t session_id;
    uint32_t frame_id;
    uint16_t packet_index;
    uint16_t flags;
    uint8_t aad[16];
    uint8_t ciphertext[CIPHERTEXT_BYTES];
    uint8_t tag[16];
};

static_assert(sizeof(RecordFile) == 1496, "unexpected record layout");

static const uint8_t h_sbox[256] = {
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16};

__device__ __constant__ uint8_t d_sbox[256] = {
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16};

static const uint32_t h_sha_k[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};

__device__ __constant__ uint32_t d_sha_k[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};

__device__ __constant__ uint8_t d_aad[16];
__device__ __constant__ uint8_t d_ciphertext[CIPHERTEXT_BYTES];
__device__ __constant__ uint8_t d_tag[16];
__device__ __constant__ uint8_t d_iv[12];

HD static inline uint32_t rotr32(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }
HD static inline uint8_t aes_sbox(uint8_t x) {
#ifdef __CUDA_ARCH__
    return d_sbox[x];
#else
    return h_sbox[x];
#endif
}
HD static inline uint32_t sha_k(unsigned i) {
#ifdef __CUDA_ARCH__
    return d_sha_k[i];
#else
    return h_sha_k[i];
#endif
}
HD static inline uint32_t load_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
HD static inline uint64_t load_be64(const uint8_t *p) {
    return ((uint64_t)load_be32(p) << 32) | load_be32(p + 4);
}
HD static inline void store_be32(uint8_t *p, uint32_t x) {
    p[0]=(uint8_t)(x>>24); p[1]=(uint8_t)(x>>16); p[2]=(uint8_t)(x>>8); p[3]=(uint8_t)x;
}

HD static void derive_key(uint32_t seed, uint8_t out[32]) {
    uint8_t block[64] = {0};
    const uint8_t label[12] = {'Z','Y','B','O','-','S','E','E','D','-','v','1'};
    uint32_t w[64];
    uint32_t a=0x6a09e667,b=0xbb67ae85,c=0x3c6ef372,d=0xa54ff53a;
    uint32_t e=0x510e527f,f=0x9b05688c,g=0x1f83d9ab,h=0x5be0cd19;
    for (int i=0;i<12;i++) block[i]=label[i];
    store_be32(block+12, seed);
    block[16]=0x80;
    block[63]=0x80; /* 16 bytes = 128 bits */
    for (int i=0;i<16;i++) w[i]=load_be32(block+4*i);
    for (int i=16;i<64;i++) {
        uint32_t s0=rotr32(w[i-15],7)^rotr32(w[i-15],18)^(w[i-15]>>3);
        uint32_t s1=rotr32(w[i-2],17)^rotr32(w[i-2],19)^(w[i-2]>>10);
        w[i]=w[i-16]+s0+w[i-7]+s1;
    }
    for (int i=0;i<64;i++) {
        uint32_t S1=rotr32(e,6)^rotr32(e,11)^rotr32(e,25);
        uint32_t ch=(e&f)^((~e)&g);
        uint32_t t1=h+S1+ch+sha_k(i)+w[i];
        uint32_t S0=rotr32(a,2)^rotr32(a,13)^rotr32(a,22);
        uint32_t maj=(a&b)^(a&c)^(b&c);
        uint32_t t2=S0+maj;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    uint32_t digest[8]={0x6a09e667+a,0xbb67ae85+b,0x3c6ef372+c,0xa54ff53a+d,
                        0x510e527f+e,0x9b05688c+f,0x1f83d9ab+g,0x5be0cd19+h};
    for(int i=0;i<8;i++) store_be32(out+4*i,digest[i]);
}

HD static inline uint32_t sub_word(uint32_t x) {
    return ((uint32_t)aes_sbox((uint8_t)(x>>24))<<24)|
           ((uint32_t)aes_sbox((uint8_t)(x>>16))<<16)|
           ((uint32_t)aes_sbox((uint8_t)(x>>8))<<8)|aes_sbox((uint8_t)x);
}
HD static void aes_expand(const uint8_t key[32], uint32_t w[60]) {
    static const uint8_t rcon[7]={1,2,4,8,16,32,64};
    for(int i=0;i<8;i++) w[i]=load_be32(key+4*i);
    for(int i=8;i<60;i++) {
        uint32_t t=w[i-1];
        if(i%8==0) t=sub_word((t<<8)|(t>>24))^((uint32_t)rcon[i/8-1]<<24);
        else if(i%8==4) t=sub_word(t);
        w[i]=w[i-8]^t;
    }
}
HD static inline uint8_t xtime(uint8_t x) { return (uint8_t)((x<<1)^((x&0x80)?0x1b:0)); }
HD static void aes_encrypt(const uint32_t w[60], const uint8_t in[16], uint8_t out[16]) {
    uint8_t s[16],t[16];
    for(int i=0;i<16;i++) s[i]=in[i];
    for(int c=0;c<4;c++) for(int r=0;r<4;r++) s[4*c+r]^=(uint8_t)(w[c]>>(24-8*r));
    for(int round=1;round<=14;round++) {
        for(int i=0;i<16;i++) s[i]=aes_sbox(s[i]);
        for(int r=0;r<4;r++) for(int c=0;c<4;c++) t[4*c+r]=s[4*((c+r)&3)+r];
        for(int i=0;i<16;i++) s[i]=t[i];
        if(round!=14) for(int c=0;c<4;c++) {
            uint8_t *q=s+4*c; uint8_t all=q[0]^q[1]^q[2]^q[3],u=q[0];
            q[0]^=all^xtime(q[0]^q[1]); q[1]^=all^xtime(q[1]^q[2]);
            q[2]^=all^xtime(q[2]^q[3]); q[3]^=all^xtime(q[3]^u);
        }
        for(int c=0;c<4;c++) for(int r=0;r<4;r++) s[4*c+r]^=(uint8_t)(w[4*round+c]>>(24-8*r));
    }
    for(int i=0;i<16;i++) out[i]=s[i];
}

struct U128 { uint64_t hi,lo; };
HD static U128 gf_mul(U128 x,U128 y) {
    U128 z={0,0},v=y;
    for(int i=0;i<128;i++) {
        uint64_t bit=i<64?((x.hi>>(63-i))&1ULL):((x.lo>>(127-i))&1ULL);
        if(bit){z.hi^=v.hi;z.lo^=v.lo;}
        uint64_t lsb=v.lo&1ULL;
        v.lo=(v.lo>>1)|(v.hi<<63); v.hi>>=1;
        if(lsb) v.hi^=0xe100000000000000ULL;
    }
    return z;
}
HD static void ghash_block(U128 *y,U128 h,const uint8_t block[16]) {
    y->hi^=load_be64(block); y->lo^=load_be64(block+8); *y=gf_mul(*y,h);
}
HD static void compute_tag(uint32_t seed,const uint8_t aad[16],const uint8_t *ct,
                           const uint8_t iv[12],uint8_t out[16]) {
    uint8_t key[32],zero[16]={0},hbytes[16],j0[16]={0},mask[16],lengths[16]={0};
    uint32_t w[60]; U128 y={0,0},h;
    derive_key(seed,key); aes_expand(key,w); aes_encrypt(w,zero,hbytes);
    h={load_be64(hbytes),load_be64(hbytes+8)};
    ghash_block(&y,h,aad);
    for(unsigned off=0;off<CIPHERTEXT_BYTES;off+=16) ghash_block(&y,h,ct+off);
    lengths[7]=0x80; lengths[14]=0x2d; lengths[15]=0x00;
    ghash_block(&y,h,lengths);
    for(int i=0;i<12;i++) j0[i]=iv[i]; j0[15]=1;
    aes_encrypt(w,j0,mask);
    uint64_t hi=y.hi^load_be64(mask),lo=y.lo^load_be64(mask+8);
    for(int i=0;i<8;i++){out[i]=(uint8_t)(hi>>(56-8*i));out[8+i]=(uint8_t)(lo>>(56-8*i));}
}

__global__ static void search_kernel(uint32_t start,uint32_t count,uint32_t *found) {
    uint32_t stride=blockDim.x*gridDim.x,idx=blockIdx.x*blockDim.x+threadIdx.x;
    for(uint32_t pos=idx;pos<count;pos+=stride) {
        uint32_t seed=start+pos; uint8_t tag[16]; bool match=true;
        compute_tag(seed,d_aad,d_ciphertext,d_iv,tag);
        for(int i=0;i<16;i++) if(tag[i]!=d_tag[i]) match=false;
        if(match) atomicMin(found,seed);
    }
}

__global__ static void tag_kernel(uint32_t start,uint32_t count,uint8_t *tags) {
    uint32_t stride=blockDim.x*gridDim.x,idx=blockIdx.x*blockDim.x+threadIdx.x;
    for(uint32_t pos=idx;pos<count;pos+=stride)
        compute_tag(start+pos,d_aad,d_ciphertext,d_iv,tags+(size_t)pos*16U);
}

struct Profile { const char *name; bool cpu; unsigned blocks,threads,work; };
static const Profile profiles[]={{"cpu-multi",true,0,0,64},{"cuda-low",false,8,64,4},
    {"cuda-mid",false,7,128,8},{"cuda-max",false,64,256,8}};

static const Profile *find_profile(const char *name){for(const auto &p:profiles)if(!strcmp(name,p.name))return &p;return nullptr;}
static double seconds_since(std::chrono::steady_clock::time_point start){return std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();}

static int write_status(const char *path,const char *phase,unsigned bits,const Profile &p,
                        uint64_t tested,uint64_t space,double elapsed,uint32_t found,
                        const char *gpu) {
    std::string tmp=std::string(path)+".tmp"; FILE *f=fopen(tmp.c_str(),"w"); if(!f)return -1;
    double rate=elapsed>0?tested/elapsed:0,progress=space?double(tested)/space:0;
    double full_scan=rate>0?space/rate:0;
    fprintf(f,"{\"implementation\":\"native-cuda-full-gcm\",\"version\":\"1.0.0\","
        "\"phase\":\"%s\",\"active\":%s,\"bits\":%u,\"key_space\":%llu,"
        "\"profile\":\"%s\",\"device\":\"%s\",\"blocks\":%u,\"threads\":%u,"
        "\"candidates_tested\":%llu,\"elapsed_s\":%.6f,\"search_rate\":%.3f,"
        "\"progress\":%.9f,\"est_full_scan_s\":%.6f,\"found_seed\":",
        phase,!strcmp(phase,"searching")?"true":"false",bits,(unsigned long long)space,p.name,gpu,p.blocks,p.threads,
        (unsigned long long)tested,elapsed,rate,progress,full_scan);
    if(found==NO_SEED) fprintf(f,"null,\"tag_verified\":false}\n");
    else fprintf(f,"%u,\"tag_verified\":true}\n",found);
    if(fclose(f)||rename(tmp.c_str(),path))return -1; return 0;
}

static bool host_match(const RecordFile &r,uint32_t seed){uint8_t iv[12],tag[16];store_be32(iv,r.session_id);store_be32(iv+4,r.frame_id);iv[8]=iv[9]=0;iv[10]=(uint8_t)(r.packet_index>>8);iv[11]=(uint8_t)r.packet_index;compute_tag(seed,r.aad,r.ciphertext,iv,tag);return !memcmp(tag,r.tag,16);}

static uint32_t cpu_batch(const RecordFile &r,uint32_t start,uint32_t count,unsigned workers) {
    std::atomic<uint32_t> found(NO_SEED); std::vector<std::thread> pool;
    for(unsigned t=0;t<workers;t++) pool.emplace_back([&,t]{for(uint32_t i=t;i<count&&!stop_requested;i+=workers){uint32_t s=start+i;if(host_match(r,s)){uint32_t expect=NO_SEED;found.compare_exchange_strong(expect,s);}}});
    for(auto &thread:pool)thread.join(); return found.load();
}

static int cross_check(const RecordFile &r,const uint8_t iv[12],const Profile &profile,
                       uint32_t count,const char *status_path,const char *device) {
    uint8_t *device_tags=nullptr; std::vector<uint8_t> gpu_tags((size_t)count*16U);
    auto started=std::chrono::steady_clock::now();
    if(cudaMalloc(&device_tags,gpu_tags.size())!=cudaSuccess)return 1;
    tag_kernel<<<profile.blocks,profile.threads>>>(0,count,device_tags);
    if(cudaDeviceSynchronize()!=cudaSuccess||cudaMemcpy(gpu_tags.data(),device_tags,
       gpu_tags.size(),cudaMemcpyDeviceToHost)!=cudaSuccess){cudaFree(device_tags);return 1;}
    cudaFree(device_tags);
    for(uint32_t seed=0;seed<count;seed++){
        uint8_t host_tag[16];compute_tag(seed,r.aad,r.ciphertext,iv,host_tag);
        if(memcmp(host_tag,gpu_tags.data()+(size_t)seed*16U,16)){
            fprintf(stderr,"CPU/CUDA tag mismatch at seed %u\n",seed);return 1;
        }
    }
    double elapsed=seconds_since(started);
    write_status(status_path,"crosscheck_complete",20,profile,count,count,elapsed,NO_SEED,device);
    printf("{\"cross_check\":\"pass\",\"candidates\":%u,\"full_tag_bytes\":16,\"elapsed_s\":%.6f}\n",count,elapsed);
    return 0;
}

static void usage(const char *name){fprintf(stderr,"usage: %s --record FILE --bits 20..26 --profile cpu-multi|cuda-low|cuda-mid|cuda-max --status FILE [--benchmark-count N | --cross-check-count 4096]\n",name);}

int main(int argc,char **argv){
    const char *record_path=nullptr,*profile_name=nullptr,*status_path=nullptr; unsigned bits=0; uint64_t benchmark_count=0; unsigned cross_check_count=0;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--record")&&i+1<argc)record_path=argv[++i];
        else if(!strcmp(argv[i],"--bits")&&i+1<argc)bits=(unsigned)strtoul(argv[++i],nullptr,10);
        else if(!strcmp(argv[i],"--profile")&&i+1<argc)profile_name=argv[++i];
        else if(!strcmp(argv[i],"--status")&&i+1<argc)status_path=argv[++i];
        else if(!strcmp(argv[i],"--benchmark-count")&&i+1<argc)benchmark_count=strtoull(argv[++i],nullptr,10);
        else if(!strcmp(argv[i],"--cross-check-count")&&i+1<argc)cross_check_count=(unsigned)strtoul(argv[++i],nullptr,10);
        else {usage(argv[0]);return 2;}
    }
    const Profile *profile=find_profile(profile_name?profile_name:"");
    if(!record_path||!status_path||!profile||bits<20||bits>26||
       (benchmark_count&&cross_check_count)||cross_check_count>MAX_CROSS_CHECK){usage(argv[0]);return 2;}
    signal(SIGINT,on_signal);signal(SIGTERM,on_signal);
    FILE *f=fopen(record_path,"rb"); RecordFile r{}; if(!f||fread(&r,1,sizeof(r),f)!=sizeof(r)){perror("read record");return 1;} fclose(f);
    if(memcmp(r.magic,RECORD_MAGIC,8)||r.version!=RECORD_VERSION||!(r.flags&1)){fprintf(stderr,"invalid encrypted record\n");return 1;}
    uint8_t iv[12];store_be32(iv,r.session_id);store_be32(iv+4,r.frame_id);iv[8]=iv[9]=0;iv[10]=(uint8_t)(r.packet_index>>8);iv[11]=(uint8_t)r.packet_index;
    cudaDeviceProp prop{}; std::string device="CPU";
    if(!profile->cpu){if(cudaGetDeviceProperties(&prop,0)!=cudaSuccess){fprintf(stderr,"CUDA device unavailable\n");return 1;}device=prop.name;cudaMemcpyToSymbol(d_aad,r.aad,16);cudaMemcpyToSymbol(d_ciphertext,r.ciphertext,CIPHERTEXT_BYTES);cudaMemcpyToSymbol(d_tag,r.tag,16);cudaMemcpyToSymbol(d_iv,iv,12);}
    if(cross_check_count){if(profile->cpu||cross_check_count==0){fprintf(stderr,"cross-check requires a CUDA profile\n");return 2;}return cross_check(r,iv,*profile,cross_check_count,status_path,device.c_str());}
    uint64_t space=1ULL<<bits,total=benchmark_count?std::min(benchmark_count,space):space,tested=0;uint32_t found=NO_SEED;auto started=std::chrono::steady_clock::now();
    write_status(status_path,"searching",bits,*profile,0,space,0,found,device.c_str());
    uint32_t *d_found=nullptr;if(!profile->cpu)cudaMalloc(&d_found,sizeof(uint32_t));
    unsigned workers=std::max(1u,std::thread::hardware_concurrency());
    while(tested<total&&found==NO_SEED&&!stop_requested){
        uint64_t desired=profile->cpu?workers*profile->work:(uint64_t)profile->blocks*profile->threads*profile->work;
        uint32_t count=(uint32_t)std::min<uint64_t>(desired,total-tested);
        if(profile->cpu) found=cpu_batch(r,(uint32_t)tested,count,workers);
        else {uint32_t init=NO_SEED;cudaMemcpy(d_found,&init,sizeof(init),cudaMemcpyHostToDevice);search_kernel<<<profile->blocks,profile->threads>>>((uint32_t)tested,count,d_found);if(cudaDeviceSynchronize()!=cudaSuccess){fprintf(stderr,"CUDA kernel failed\n");return 1;}cudaMemcpy(&found,d_found,sizeof(found),cudaMemcpyDeviceToHost);}
        if(benchmark_count) found=NO_SEED;
        tested+=count;write_status(status_path,found==NO_SEED?"searching":"found",bits,*profile,tested,space,seconds_since(started),found,device.c_str());
    }
    if(d_found)cudaFree(d_found);double elapsed=seconds_since(started);const char *phase=found!=NO_SEED?"found":stop_requested?"stopped":(benchmark_count?"benchmark_complete":"not_found");write_status(status_path,phase,bits,*profile,tested,space,elapsed,found,device.c_str());
    printf("{\"profile\":\"%s\",\"tested\":%llu,\"elapsed_s\":%.6f,\"keys_per_s\":%.3f,\"found_seed\":",profile->name,(unsigned long long)tested,elapsed,elapsed>0?tested/elapsed:0);if(found==NO_SEED)printf("null");else printf("%u",found);printf(",\"tag_verified\":%s}\n",found==NO_SEED?"false":"true");
    return benchmark_count||found!=NO_SEED||stop_requested?0:3;
}
