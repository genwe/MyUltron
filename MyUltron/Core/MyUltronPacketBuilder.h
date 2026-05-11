//
//  MyUltronPacketBuilder.h
//  MyUltron
//
//  C++ packet builder/decoder (mirrors MyUltronServer).
//

#ifndef MyUltronPacketBuilder_h
#define MyUltronPacketBuilder_h

#import <Foundation/Foundation.h>
#include "MyUltronPacket.h"

class MyUltronPacketBuilder {
public:
    MyUltronPacketBuilder();
    ~MyUltronPacketBuilder();

    void buildPingPacket();
    void buildPongPacket();
    void buildTextPacket(NSString *text);
    void buildBinaryPacket(NSData *data);
    void buildJsonPacket(NSDictionary *dict);

    myultron_packet_t* getPacket();

    void decodePacket(NSData *data);

private:
    void resetPacket();
    void doBuildPacket(NSData *data, MyUltronPacketType type);
    myultron_packet_t *packet;
};

#endif /* MyUltronPacketBuilder_h */
