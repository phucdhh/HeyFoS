#ifndef LIBRAW_C_WRAPPER_H
#define LIBRAW_C_WRAPPER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque pointer to LibRaw processor
typedef void* libraw_processor_t;

// Image data structure
typedef struct {
    int width;
    int height;
    int channels;
    float* data;  // Float32 RGB data (linear)
    size_t data_size;
} libraw_image_data_t;

// Metadata structure
typedef struct {
    char make[64];
    char model[64];
    int iso_speed;
    float shutter_speed;
    float aperture;
    float focal_length;
    float wb_r;
    float wb_g;
    float wb_b;
} libraw_metadata_t;

// Initialize LibRaw processor
libraw_processor_t heyfos_libraw_init(void);

// Free LibRaw processor
void heyfos_libraw_cleanup(libraw_processor_t processor);

// Open RAW file
int heyfos_libraw_open_file(libraw_processor_t processor, const char* filename);

// Unpack RAW data
int heyfos_libraw_unpack(libraw_processor_t processor);

// Process RAW to linear RGB (no gamma, white balance applied)
int heyfos_libraw_process_linear(libraw_processor_t processor);

// Get processed image data as float32 RGB
libraw_image_data_t* heyfos_libraw_get_image_data(libraw_processor_t processor);

// Get metadata
libraw_metadata_t* heyfos_libraw_get_metadata(libraw_processor_t processor);

// Free image data
void heyfos_libraw_free_image_data(libraw_image_data_t* data);

// Free metadata
void heyfos_libraw_free_metadata(libraw_metadata_t* metadata);

// Get error message
const char* heyfos_libraw_get_error(libraw_processor_t processor);

#ifdef __cplusplus
}
#endif

#endif // LIBRAW_C_WRAPPER_H
