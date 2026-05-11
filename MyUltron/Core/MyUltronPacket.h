//
//  MyUltronPacket.h
//  MyUltron
//
//  Packet protocol definitions (shared with MyUltronServer).
//

#ifndef MyUltronPacket_h
#define MyUltronPacket_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum MyUltronPacketType {
    MyUltronPacketTypePing          = 1010,
    MyUltronPacketTypePong          = 1020,
    MyUltronPacketTypeTextMessage   = 1110,
    MyUltronPacketTypeBinaryMessage = 1120,
    MyUltronPacketTypeJsonMessage   = 1130,
};
typedef enum MyUltronPacketType MyUltronPacketType;

typedef struct myultron_packet_header {
    int32_t length;
    int32_t version;
    int32_t packetType;
    int32_t tag;
} myultron_packet_header_t;

typedef struct myultron_packet {
    myultron_packet_header_t header;
    uint8_t payload[];
} myultron_packet_t;

#define MYULTRON_PACKET_HEADER_SIZE   sizeof(myultron_packet_header_t)
#define MYULTRON_PACKET_LENGTH_BYTES  4

#ifdef __cplusplus
}
#endif

#endif /* MyUltronPacket_h */
