#ifndef GALAXY_CALLING_MEDIA_H
#define GALAXY_CALLING_MEDIA_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct cmc_codec *cmc_codec_ref;
typedef struct cmc_srtp *cmc_srtp_ref;
cmc_codec_ref cmc_codec_create(void);
void cmc_codec_destroy(cmc_codec_ref codec);
int cmc_amrwb_encode(cmc_codec_ref codec, const int16_t *samples, uint8_t *frame, size_t capacity, int mode);
int cmc_amrwb_decode(cmc_codec_ref codec, const uint8_t *frame, size_t size, int16_t *samples);
cmc_srtp_ref cmc_srtp_create(const uint8_t *outbound_key, const uint8_t *inbound_key, uint32_t ssrc, int tag_bytes);
void cmc_srtp_destroy(cmc_srtp_ref session);
size_t cmc_srtp_trailer_size(void);
int cmc_srtp_protect(cmc_srtp_ref session, uint8_t *packet, int *size);
int cmc_srtp_unprotect(cmc_srtp_ref session, uint8_t *packet, int *size);
#ifdef __cplusplus
}
#endif
#endif
