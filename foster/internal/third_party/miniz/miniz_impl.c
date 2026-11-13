#include "miniz.c"

size_t jf_mz_zip_archive_size(void) {
    return sizeof(mz_zip_archive);
}

size_t jf_mz_stat_size(void) {
    return sizeof(mz_zip_archive_file_stat);
}

int jf_mz_uncompress(unsigned char *pDest, size_t *pDest_len, const unsigned char *pSource, size_t source_len) {
    return mz_uncompress(pDest, pDest_len, pSource, source_len);
}
