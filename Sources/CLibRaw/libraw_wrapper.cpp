#include "libraw_wrapper.h"
#include <libraw/libraw.h>
#include <string.h>
#include <stdlib.h>

// Initialize LibRaw processor
libraw_processor_t heyfos_libraw_init(void) {
    LibRaw* processor = new LibRaw();
    return (libraw_processor_t)processor;
}

// Free LibRaw processor
void heyfos_libraw_cleanup(libraw_processor_t processor) {
    if (processor) {
        LibRaw* raw = (LibRaw*)processor;
        delete raw;
    }
}

// Open RAW file
int heyfos_libraw_open_file(libraw_processor_t processor, const char* filename) {
    if (!processor || !filename) return -1;
    LibRaw* raw = (LibRaw*)processor;
    return raw->open_file(filename);
}

// Unpack RAW data
int heyfos_libraw_unpack(libraw_processor_t processor) {
    if (!processor) return -1;
    LibRaw* raw = (LibRaw*)processor;
    return raw->unpack();
}

// Process RAW to linear RGB
int heyfos_libraw_process_linear(libraw_processor_t processor) {
    if (!processor) return -1;
    LibRaw* raw = (LibRaw*)processor;
    
    // Set processing parameters for linear output
    raw->imgdata.params.output_bps = 16;
    raw->imgdata.params.output_color = 1; // sRGB
    raw->imgdata.params.gamm[0] = 1.0;    // Linear gamma
    raw->imgdata.params.gamm[1] = 1.0;
    raw->imgdata.params.no_auto_bright = 1;
    raw->imgdata.params.use_camera_wb = 1;
    
    return raw->dcraw_process();
}

// Get processed image data as float32 RGB
libraw_image_data_t* heyfos_libraw_get_image_data(libraw_processor_t processor) {
    if (!processor) return NULL;
    LibRaw* raw = (LibRaw*)processor;
    
    libraw_processed_image_t* img = raw->dcraw_make_mem_image();
    if (!img) return NULL;
    
    libraw_image_data_t* data = (libraw_image_data_t*)malloc(sizeof(libraw_image_data_t));
    if (!data) {
        LibRaw::dcraw_clear_mem(img);
        return NULL;
    }
    
    data->width = img->width;
    data->height = img->height;
    data->channels = img->colors;
    
    // Convert uint16 to float32 (normalized to 0-1)
    size_t pixel_count = data->width * data->height * data->channels;
    data->data_size = pixel_count * sizeof(float);
    data->data = (float*)malloc(data->data_size);
    
    if (!data->data) {
        free(data);
        LibRaw::dcraw_clear_mem(img);
        return NULL;
    }
    
    uint16_t* src = (uint16_t*)img->data;
    for (size_t i = 0; i < pixel_count; i++) {
        data->data[i] = (float)src[i] / 65535.0f;
    }
    
    LibRaw::dcraw_clear_mem(img);
    return data;
}

// Get metadata
libraw_metadata_t* heyfos_libraw_get_metadata(libraw_processor_t processor) {
    if (!processor) return NULL;
    LibRaw* raw = (LibRaw*)processor;
    
    libraw_metadata_t* meta = (libraw_metadata_t*)malloc(sizeof(libraw_metadata_t));
    if (!meta) return NULL;
    
    memset(meta, 0, sizeof(libraw_metadata_t));
    
    // Copy metadata
    strncpy(meta->make, raw->imgdata.idata.make, sizeof(meta->make) - 1);
    strncpy(meta->model, raw->imgdata.idata.model, sizeof(meta->model) - 1);
    
    meta->iso_speed = (int)raw->imgdata.other.iso_speed;
    meta->shutter_speed = raw->imgdata.other.shutter;
    meta->aperture = raw->imgdata.other.aperture;
    meta->focal_length = raw->imgdata.other.focal_len;
    
    // White balance multipliers
    meta->wb_r = raw->imgdata.color.cam_mul[0];
    meta->wb_g = raw->imgdata.color.cam_mul[1];
    meta->wb_b = raw->imgdata.color.cam_mul[2];
    
    return meta;
}

// Free image data
void heyfos_libraw_free_image_data(libraw_image_data_t* data) {
    if (data) {
        if (data->data) {
            free(data->data);
        }
        free(data);
    }
}

// Free metadata
void heyfos_libraw_free_metadata(libraw_metadata_t* metadata) {
    if (metadata) {
        free(metadata);
    }
}

// Get error message
const char* heyfos_libraw_get_error(libraw_processor_t processor) {
    if (!processor) return "Invalid processor";
    LibRaw* raw = (LibRaw*)processor;
    return libraw_strerror(raw->imgdata.process_warnings);
}
