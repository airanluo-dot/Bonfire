#pragma once
extern "C" {
#include "../vendor/puff.h"
}

namespace transfer {
inline int inflateRaw(unsigned char* output, unsigned long* outputSize,
                      const unsigned char* input, unsigned long* inputSize) {
    // puff builds its fixed Huffman tables lazily. Initialize them once, before
    // concurrent library scans can enter the C decoder.
    static const bool ready = [] {
        const unsigned char emptyFixedBlock[] = {3, 0};
        unsigned char unused{};
        unsigned long size = 0, compressed = sizeof(emptyFixedBlock);
        return puff(&unused, &size, emptyFixedBlock, &compressed) == 0;
    }();
    return ready ? puff(output, outputSize, input, inputSize) : -1;
}
}
