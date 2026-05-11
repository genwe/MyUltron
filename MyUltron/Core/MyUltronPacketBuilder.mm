//
//  MyUltronPacketBuilder.mm
//  MyUltron
//
//  Packet builder implementation (mirrors MyUltronServer).
//

#include "MyUltronPacketBuilder.h"
#include <cstdlib>
#include <cstring>

MyUltronPacketBuilder::MyUltronPacketBuilder() : packet(NULL) {}

MyUltronPacketBuilder::~MyUltronPacketBuilder() {
    resetPacket();
}

void MyUltronPacketBuilder::resetPacket() {
    if (packet != NULL) {
        free(packet);
        packet = NULL;
    }
}

void MyUltronPacketBuilder::buildPingPacket() {
    resetPacket();
    NSData *data = [@"ping" dataUsingEncoding:NSUTF8StringEncoding];
    doBuildPacket(data, MyUltronPacketTypePing);
}

void MyUltronPacketBuilder::buildPongPacket() {
    resetPacket();
    NSData *data = [@"pong" dataUsingEncoding:NSUTF8StringEncoding];
    doBuildPacket(data, MyUltronPacketTypePong);
}

void MyUltronPacketBuilder::buildTextPacket(NSString *text) {
    resetPacket();
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    doBuildPacket(data, MyUltronPacketTypeTextMessage);
}

void MyUltronPacketBuilder::buildBinaryPacket(NSData *data) {
    resetPacket();
    doBuildPacket(data, MyUltronPacketTypeBinaryMessage);
}

void MyUltronPacketBuilder::buildJsonPacket(NSDictionary *dict) {
    resetPacket();
    if (![NSJSONSerialization isValidJSONObject:dict]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    doBuildPacket(data, MyUltronPacketTypeJsonMessage);
}

myultron_packet_t* MyUltronPacketBuilder::getPacket() {
    return packet;
}

void MyUltronPacketBuilder::doBuildPacket(NSData *data, MyUltronPacketType type) {
    size_t payloadLen  = data.length;
    size_t totalLength = MYULTRON_PACKET_HEADER_SIZE + payloadLen;
    packet = (myultron_packet_t *)malloc(totalLength);
    if (packet == NULL) return;
    packet->header.length     = (int32_t)totalLength;
    packet->header.version    = 1;
    packet->header.packetType = type;
    packet->header.tag        = 0;
    memcpy(packet->payload, data.bytes, payloadLen);
}

void MyUltronPacketBuilder::decodePacket(NSData *data) {
    resetPacket();
    if (data.length < MYULTRON_PACKET_HEADER_SIZE) return;
    size_t len = data.length;
    packet = (myultron_packet_t *)malloc(len);
    if (packet == NULL) return;
    const int32_t *fields = (const int32_t *)data.bytes;
    packet->header.length     = fields[0];
    packet->header.version    = fields[1];
    packet->header.packetType = fields[2];
    packet->header.tag        = fields[3];
    size_t payloadLen = len - MYULTRON_PACKET_HEADER_SIZE;
    if (payloadLen > 0) {
        memcpy(packet->payload,
               (const uint8_t *)data.bytes + MYULTRON_PACKET_HEADER_SIZE,
               payloadLen);
    }
}
