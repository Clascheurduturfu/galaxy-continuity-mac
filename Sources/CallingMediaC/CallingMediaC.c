#include "CallingMediaC.h"
#include <vo-amrwbenc/enc_if.h>
#include <opencore-amrwb/dec_if.h>
#include <srtp2/srtp.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

struct cmc_codec { void *encoder; void *decoder; };
struct cmc_srtp { srtp_t outbound; srtp_t inbound; };
static pthread_once_t srtp_once = PTHREAD_ONCE_INIT;
static int srtp_ready = 0;
static void initialize_srtp(void) { srtp_ready = srtp_init() == srtp_err_status_ok; }

cmc_codec_ref cmc_codec_create(void) {
    cmc_codec_ref codec = calloc(1, sizeof(*codec));
    if (!codec) return NULL;
    codec->encoder = E_IF_init(); codec->decoder = D_IF_init();
    if (!codec->encoder || !codec->decoder) { cmc_codec_destroy(codec); return NULL; }
    return codec;
}
void cmc_codec_destroy(cmc_codec_ref codec) {
    if (!codec) return;
    if (codec->encoder) E_IF_exit(codec->encoder);
    if (codec->decoder) D_IF_exit(codec->decoder);
    free(codec);
}
int cmc_amrwb_encode(cmc_codec_ref codec, const int16_t *samples, uint8_t *frame, size_t capacity, int mode) {
    if (!codec || !samples || !frame || capacity < 64 || mode < 0 || mode > 8) return -1;
    return E_IF_encode(codec->encoder, mode, samples, frame, 0);
}
int cmc_amrwb_decode(cmc_codec_ref codec, const uint8_t *frame, size_t size, int16_t *samples) {
    static const size_t sizes[] = {18,24,33,37,41,47,51,59,61,6,0,0,0,0,1,1};
    if (!codec || !frame || !samples || !size || size > 64) return -1;
    unsigned type = (frame[0] >> 3) & 15;
    if (!sizes[type] || size != sizes[type]) return -1;
    uint8_t padded[128] = {0}; memcpy(padded, frame, size); padded[0] &= 0x7f;
    D_IF_decode(codec->decoder, padded, samples, type == 14 || !(frame[0] & 4));
    return 320;
}
cmc_srtp_ref cmc_srtp_create(const uint8_t *out_key, const uint8_t *in_key, uint32_t ssrc, int tag_bytes) {
    if (!out_key || !in_key || (tag_bytes != 4 && tag_bytes != 10)) return NULL;
    pthread_once(&srtp_once, initialize_srtp);
    if (!srtp_ready) return NULL;
    cmc_srtp_ref result = calloc(1, sizeof(*result));
    if (!result) return NULL;
    srtp_policy_t policy; memset(&policy, 0, sizeof(policy));
    if (tag_bytes == 4) srtp_crypto_policy_set_aes_cm_128_hmac_sha1_32(&policy.rtp);
    else srtp_crypto_policy_set_aes_cm_128_hmac_sha1_80(&policy.rtp);
    srtp_crypto_policy_set_aes_cm_128_hmac_sha1_80(&policy.rtcp);
    policy.ssrc.type = ssrc_specific; policy.ssrc.value = ssrc;
    policy.key = (uint8_t *)out_key; policy.window_size = 128;
    if (srtp_create(&result->outbound, &policy) != srtp_err_status_ok) { cmc_srtp_destroy(result); return NULL; }
    policy.ssrc.type = ssrc_any_inbound; policy.ssrc.value = 0; policy.key = (uint8_t *)in_key;
    if (srtp_create(&result->inbound, &policy) != srtp_err_status_ok) { cmc_srtp_destroy(result); return NULL; }
    return result;
}
void cmc_srtp_destroy(cmc_srtp_ref session) {
    if (!session) return;
    if (session->outbound) srtp_dealloc(session->outbound);
    if (session->inbound) srtp_dealloc(session->inbound);
    free(session);
}
size_t cmc_srtp_trailer_size(void) { return SRTP_MAX_TRAILER_LEN; }
int cmc_srtp_protect(cmc_srtp_ref session, uint8_t *packet, int *size) {
    if (!session || !packet || !size || *size < 12) return -1;
    return srtp_protect(session->outbound, packet, size);
}
int cmc_srtp_unprotect(cmc_srtp_ref session, uint8_t *packet, int *size) {
    if (!session || !packet || !size || *size < 16) return -1;
    return srtp_unprotect(session->inbound, packet, size);
}
