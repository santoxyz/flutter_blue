// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#if __has_include(<flutter_blue/flutter_blue-Swift.h>)
#import <flutter_blue/flutter_blue-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "flutter_blue-Swift.h"
#endif

#import "FlutterBluePlugin.h"
#import "Flutterblue.pbobjc.h"
#import "FlutterMidiSynthPlugin.h"

@interface CBUUID (CBUUIDAdditionsFlutterBlue)
- (NSString *)fullUUIDString;
@end

@implementation CBUUID (CBUUIDAdditionsFlutterBlue)
- (NSString *)fullUUIDString {
  if(self.UUIDString.length == 4) {
    return [[NSString stringWithFormat:@"0000%@-0000-1000-8000-00805F9B34FB", self.UUIDString] lowercaseString];
  }
  return [self.UUIDString lowercaseString];
}
@end

typedef NS_ENUM(NSUInteger, LogLevel) {
  emergency = 0,
  alert = 1,
  critical = 2,
  error = 3,
  warning = 4,
  notice = 5,
  info = 6,
  debug = 7
};

@interface FlutterBluePlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *channel;
@property(nonatomic, retain) FlutterBlueStreamHandler *stateStreamHandler;
@property(nonatomic, retain) CBCentralManager *centralManager;
@property(nonatomic) NSMutableDictionary *scannedPeripherals;
@property(nonatomic) NSMutableArray *servicesThatNeedDiscovered;
@property(nonatomic) NSMutableArray *characteristicsThatNeedDiscovered;
@property(nonatomic) LogLevel logLevel;
@property(nonatomic, retain) SwiftFlutterMidiSynthPlugin *midiSynth;

@end

@implementation FlutterBluePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
                                   methodChannelWithName:NAMESPACE @"/methods"
                                   binaryMessenger:[registrar messenger]];
  FlutterEventChannel* stateChannel = [FlutterEventChannel eventChannelWithName:NAMESPACE @"/state" binaryMessenger:[registrar messenger]];
  FlutterBluePlugin* instance = [[FlutterBluePlugin alloc] init];
  instance.channel = channel;
  instance.centralManager = [[CBCentralManager alloc] initWithDelegate:instance queue:nil];
  instance.scannedPeripherals = [NSMutableDictionary new];
  instance.servicesThatNeedDiscovered = [NSMutableArray new];
  instance.characteristicsThatNeedDiscovered = [NSMutableArray new];
  instance.logLevel = emergency;
  
  // STATE
  FlutterBlueStreamHandler* stateStreamHandler = [[FlutterBlueStreamHandler alloc] init];
  [stateChannel setStreamHandler:stateStreamHandler];
  instance.stateStreamHandler = stateStreamHandler;
  
  [registrar addMethodCallDelegate:instance channel:channel];

  //FlutterMidiSynthPlugin
  //[SwiftFlutterMidiSynthPlugin registerWithRegistrar:registrar];
  instance.midiSynth = [[SwiftFlutterMidiSynthPlugin alloc] init];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"setLogLevel" isEqualToString:call.method]) {
    NSNumber *logLevelIndex = [call arguments];
    _logLevel = (LogLevel)[logLevelIndex integerValue];
    result(nil);
  } else if ([@"state" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [self toFlutterData:[self toBluetoothStateProto:self->_centralManager.state]];
    result(data);
  } else if([@"isAvailable" isEqualToString:call.method]) {
    if(self.centralManager.state != CBManagerStateUnsupported && self.centralManager.state != CBManagerStateUnknown) {
      result(@(YES));
    } else {
      result(@(NO));
    }
  } else if([@"isOn" isEqualToString:call.method]) {
    if(self.centralManager.state == CBManagerStatePoweredOn) {
      result(@(YES));
    } else {
      result(@(NO));
    }
  } else if([@"startScan" isEqualToString:call.method]) {
    // Clear any existing scan results
    [self.scannedPeripherals removeAllObjects];
    // TODO: Request Permission?
    FlutterStandardTypedData *data = [call arguments];
    ProtosScanSettings *request = [[ProtosScanSettings alloc] initWithData:[data data] error:nil];
    // UUID Service filter
    NSArray *uuids = [NSArray array];
    for (int i = 0; i < [request serviceUuidsArray_Count]; i++) {
      NSString *u = [request.serviceUuidsArray objectAtIndex:i];
      uuids = [uuids arrayByAddingObject:[CBUUID UUIDWithString:u]];
    }
    NSMutableDictionary<NSString *, id> *scanOpts = [NSMutableDictionary new];
    if (request.allowDuplicates) {
        [scanOpts setObject:[NSNumber numberWithBool:YES] forKey:CBCentralManagerScanOptionAllowDuplicatesKey];
    }
    [self->_centralManager scanForPeripheralsWithServices:uuids options:scanOpts];
    result(nil);
  } else if([@"stopScan" isEqualToString:call.method]) {
    [self->_centralManager stopScan];
    result(nil);
  } else if([@"getConnectedDevices" isEqualToString:call.method]) {
    // Cannot pass blank UUID list for security reasons. Assume all devices have the Generic Access service 0x1800
    NSArray *periphs = [self->_centralManager retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:@"1800"]]];
    NSLog(@"getConnectedDevices periphs size: %lu", [periphs count]);
    result([self toFlutterData:[self toConnectedDeviceResponseProto:periphs]]);
  } else if([@"connect" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [call arguments];
    ProtosConnectRequest *request = [[ProtosConnectRequest alloc] initWithData:[data data] error:nil];
    NSString *remoteId = [request remoteId];
    @try {
      CBPeripheral *peripheral = [_scannedPeripherals objectForKey:remoteId];
      if(peripheral == nil) {
        @throw [FlutterError errorWithCode:@"connect"
                                   message:@"Peripheral not found"
                                   details:nil];
      }
      // TODO: Implement Connect options (#36)
      [_centralManager connectPeripheral:peripheral options:nil];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"disconnect" isEqualToString:call.method]) {
    NSString *remoteId = [call arguments];
    @try {
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      [_centralManager cancelPeripheralConnection:peripheral];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"deviceState" isEqualToString:call.method]) {
    NSString *remoteId = [call arguments];
    @try {
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      result([self toFlutterData:[self toDeviceStateProto:peripheral state:peripheral.state]]);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"discoverServices" isEqualToString:call.method]) {
    NSString *remoteId = [call arguments];
    @try {
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      // Clear helper arrays
      [_servicesThatNeedDiscovered removeAllObjects];
      [_characteristicsThatNeedDiscovered removeAllObjects ];
      [peripheral discoverServices:nil];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"services" isEqualToString:call.method]) {
    NSString *remoteId = [call arguments];
    @try {
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      result([self toFlutterData:[self toServicesResultProto:peripheral]]);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"readCharacteristic" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [call arguments];
    ProtosReadCharacteristicRequest *request = [[ProtosReadCharacteristicRequest alloc] initWithData:[data data] error:nil];
    NSString *remoteId = [request remoteId];
    @try {
      // Find peripheral
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      // Find characteristic
      CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
      // Trigger a read
      [peripheral readValueForCharacteristic:characteristic];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"SNTX readDescriptor" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [call arguments];
    ProtosReadDescriptorRequest *request = [[ProtosReadDescriptorRequest alloc] initWithData:[data data] error:nil];
    NSString *remoteId = [request remoteId];
    @try {
      // Find peripheral
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      // Find characteristic
      CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
      // Find descriptor
      CBDescriptor *descriptor = [self locateDescriptor:[request descriptorUuid] characteristic:characteristic];
      [peripheral readValueForDescriptor:descriptor];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"writeCharacteristic" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [call arguments];
    ProtosWriteCharacteristicRequest *request = [[ProtosWriteCharacteristicRequest alloc] initWithData:[data data] error:nil];
    NSString *remoteId = [request remoteId];
    @try {
      // Find peripheral
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      // Find characteristic
      CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
      // Get correct write type
      CBCharacteristicWriteType type = ([request writeType] == ProtosWriteCharacteristicRequest_WriteType_WithoutResponse) ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
      // Write to characteristic
      NSLog(@"writeCharacteristic %@ (%@)",[request value],characteristic);

      [peripheral writeValue:[request value] forCharacteristic:characteristic type:type];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"writeDescriptor" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [call arguments];
    ProtosWriteDescriptorRequest *request = [[ProtosWriteDescriptorRequest alloc] initWithData:[data data] error:nil];
    NSString *remoteId = [request remoteId];
    @try {
      // Find peripheral
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      // Find characteristic
      CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
      // Find descriptor
      CBDescriptor *descriptor = [self locateDescriptor:[request descriptorUuid] characteristic:characteristic];
      // Write descriptor
      [peripheral writeValue:[request value] forDescriptor:descriptor];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"setNotification" isEqualToString:call.method]) {
    FlutterStandardTypedData *data = [call arguments];
    ProtosSetNotificationRequest *request = [[ProtosSetNotificationRequest alloc] initWithData:[data data] error:nil];
    NSString *remoteId = [request remoteId];
    @try {
      // Find peripheral
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      // Find characteristic
      CBCharacteristic *characteristic = [self locateCharacteristic:[request characteristicUuid] peripheral:peripheral serviceId:[request serviceUuid] secondaryServiceId:[request secondaryServiceUuid]];
      // Set notification value
      [peripheral setNotifyValue:[request enable] forCharacteristic:characteristic];
      result(nil);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"mtu" isEqualToString:call.method]) {
    NSString *remoteId = [call arguments];
    @try {
      CBPeripheral *peripheral = [self findPeripheral:remoteId];
      uint32_t mtu = [self getMtu:peripheral];
      result([self toFlutterData:[self toMtuSizeResponseProto:peripheral mtu:mtu]]);
    } @catch(FlutterError *e) {
      result(e);
    }
  } else if([@"requestMtu" isEqualToString:call.method]) {
    result([FlutterError errorWithCode:@"requestMtu" message:@"iOS does not allow mtu requests to the peripheral" details:NULL]);
  }

  //FlutterMidiSynthPlugin
  else if(
    [@"initSynth" isEqualToString:call.method] ||
    [@"setInstrument" isEqualToString:call.method] ||
    [@"noteOn" isEqualToString:call.method] ||
    [@"noteOff" isEqualToString:call.method] ||
    [@"midiEvent" isEqualToString:call.method] ||
    [@"setReverb" isEqualToString:call.method] ||
    [@"setDelay" isEqualToString:call.method]
    ) {
      [_midiSynth handleMethodCall:call result:result];
    }
  //FINE FlutterMidiSynthPlugin
  else {
    result(FlutterMethodNotImplemented);
  }
}

- (CBPeripheral*)findPeripheral:(NSString*)remoteId {
  NSArray<CBPeripheral*> *peripherals = [_centralManager retrievePeripheralsWithIdentifiers:@[[[NSUUID alloc] initWithUUIDString:remoteId]]];
  CBPeripheral *peripheral;
  for(CBPeripheral *p in peripherals) {
    if([[p.identifier UUIDString] isEqualToString:remoteId]) {
      peripheral = p;
      break;
    }
  }
  if(peripheral == nil) {
    @throw [FlutterError errorWithCode:@"findPeripheral"
                               message:@"Peripheral not found"
                               details:nil];
  }
  return peripheral;
}

- (CBCharacteristic*)locateCharacteristic:(NSString*)characteristicId peripheral:(CBPeripheral*)peripheral serviceId:(NSString*)serviceId secondaryServiceId:(NSString*)secondaryServiceId {
  CBService *primaryService = [self getServiceFromArray:serviceId array:[peripheral services]];
  if(primaryService == nil || [primaryService isPrimary] == false) {
    @throw [FlutterError errorWithCode:@"locateCharacteristic"
                               message:@"service could not be located on the device"
                               details:nil];
  }
  CBService *secondaryService;
  if(secondaryServiceId.length) {
    secondaryService = [self getServiceFromArray:secondaryServiceId array:[primaryService includedServices]];
    @throw [FlutterError errorWithCode:@"locateCharacteristic"
                               message:@"secondary service could not be located on the device"
                               details:secondaryServiceId];
  }
  CBService *service = (secondaryService != nil) ? secondaryService : primaryService;
  CBCharacteristic *characteristic = [self getCharacteristicFromArray:characteristicId array:[service characteristics]];
  if(characteristic == nil) {
    @throw [FlutterError errorWithCode:@"locateCharacteristic"
                               message:@"characteristic could not be located on the device"
                               details:nil];
  }
  return characteristic;
}

- (CBDescriptor*)locateDescriptor:(NSString*)descriptorId characteristic:(CBCharacteristic*)characteristic {
  CBDescriptor *descriptor = [self getDescriptorFromArray:descriptorId array:[characteristic descriptors]];
  if(descriptor == nil) {
    @throw [FlutterError errorWithCode:@"locateDescriptor"
                               message:@"descriptor could not be located on the device"
                               details:nil];
  }
  return descriptor;
}

// Reverse search to find primary service
- (CBService*)findPrimaryService:(CBService*)secondaryService peripheral:(CBPeripheral*)peripheral {
  for(CBService *s in [peripheral services]) {
    for(CBService *ss in [s includedServices]) {
      if([[ss.UUID UUIDString] isEqualToString:[secondaryService.UUID UUIDString]]) {
        return s;
      }
    }
  }
  return nil;
}

- (CBDescriptor*)findCCCDescriptor:(CBCharacteristic*)characteristic {
  for(CBDescriptor *d in characteristic.descriptors) {
    if([d.UUID.UUIDString isEqualToString:@"2902"]) {
      return d;
    }
  }
  return nil;
}

- (CBService*)getServiceFromArray:(NSString*)uuidString array:(NSArray<CBService*>*)array {
  for(CBService *s in array) {
    if([[s UUID] isEqual:[CBUUID UUIDWithString:uuidString]]) {
      return s;
    }
  }
  return nil;
}

- (CBCharacteristic*)getCharacteristicFromArray:(NSString*)uuidString array:(NSArray<CBCharacteristic*>*)array {
  for(CBCharacteristic *c in array) {
    if([[c UUID] isEqual:[CBUUID UUIDWithString:uuidString]]) {
      return c;
    }
  }
  return nil;
}

- (CBDescriptor*)getDescriptorFromArray:(NSString*)uuidString array:(NSArray<CBDescriptor*>*)array {
  for(CBDescriptor *d in array) {
    if([[d UUID] isEqual:[CBUUID UUIDWithString:uuidString]]) {
      return d;
    }
  }
  return nil;
}

//
// CBCentralManagerDelegate methods
//
- (void)centralManagerDidUpdateState:(nonnull CBCentralManager *)central {
  if(_stateStreamHandler.sink != nil) {
    FlutterStandardTypedData *data = [self toFlutterData:[self toBluetoothStateProto:self->_centralManager.state]];
    self.stateStreamHandler.sink(data);
  }
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
  [self.scannedPeripherals setObject:peripheral
                              forKey:[[peripheral identifier] UUIDString]];
  ProtosScanResult *result = [self toScanResultProto:peripheral advertisementData:advertisementData RSSI:RSSI];
  [_channel invokeMethod:@"ScanResult" arguments:[self toFlutterData:result]];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
  NSLog(@"SNTX didConnectPeripheral");
  // Register self as delegate for peripheral
  peripheral.delegate = self;
  
  // Send initial mtu size
  uint32_t mtu = [self getMtu:peripheral];
  [_channel invokeMethod:@"MtuSize" arguments:[self toFlutterData:[self toMtuSizeResponseProto:peripheral mtu:mtu]]];
  
  // Send connection state
  [_channel invokeMethod:@"DeviceState" arguments:[self toFlutterData:[self toDeviceStateProto:peripheral state:peripheral.state]]];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
  NSLog(@"didDisconnectPeripheral");
  // Unregister self as delegate for peripheral, not working #42
  peripheral.delegate = nil;
  
  // Send connection state
  [_channel invokeMethod:@"DeviceState" arguments:[self toFlutterData:[self toDeviceStateProto:peripheral state:peripheral.state]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
  // TODO:?
}

//
// CBPeripheralDelegate methods
//
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
  NSLog(@"didDiscoverServices");
  // Send negotiated mtu size
  uint32_t mtu = [self getMtu:peripheral];
  [_channel invokeMethod:@"MtuSize" arguments:[self toFlutterData:[self toMtuSizeResponseProto:peripheral mtu:mtu]]];
  
  // Loop through and discover characteristics and secondary services
  [_servicesThatNeedDiscovered addObjectsFromArray:peripheral.services];
  for(CBService *s in [peripheral services]) {
    NSLog(@"  Found service: %@", [s.UUID UUIDString]);
    [peripheral discoverCharacteristics:nil forService:s];
    // [peripheral discoverIncludedServices:nil forService:s]; // Secondary services in the future (#8)
  }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
  NSLog(@"didDiscoverCharacteristicsForService %@",service );
  // Loop through and discover descriptors for characteristics
  [_servicesThatNeedDiscovered removeObject:service];
  [_characteristicsThatNeedDiscovered addObjectsFromArray:service.characteristics];
  for(CBCharacteristic *c in [service characteristics]) {
    [peripheral discoverDescriptorsForCharacteristic:c];
  }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
  NSLog(@"SNTX didDiscoverDescriptorsForCharacteristic %@",characteristic);
  [_characteristicsThatNeedDiscovered removeObject:characteristic];
  if(_servicesThatNeedDiscovered.count > 0 || _characteristicsThatNeedDiscovered.count > 0) {
    // Still discovering
    return;
  }
  // Send updated tree
  ProtosDiscoverServicesResult *result = [self toServicesResultProto:peripheral];
  [_channel invokeMethod:@"DiscoverServicesResult" arguments:[self toFlutterData:result]];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverIncludedServicesForService:(CBService *)service error:(NSError *)error {
  NSLog(@"didDiscoverIncludedServicesForService");
  // Loop through and discover characteristics for secondary services
  for(CBService *ss in [service includedServices]) {
    [peripheral discoverCharacteristics:nil forService:ss];
  }
}

- (bool) isSysex:(NSData*) data {
    if (data.length - 2 < 6){
        NSLog(@"isSysex: false (short)");
        return false;
    }
    
    const char *bytes = [data bytes];
    
    
    const char header[] = { 0xF0, 0x0, 0x2F, 0x7f, 0x0, 0x1};
    unsigned char hdr[] = {bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7]};
    //NSLog(@"isSysex: hdr=[%02x %02x %02x %02x %02x %02x] tail=[%02x]",bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[data.length -1] );

    if ((unsigned char)bytes[data.length -1] == 0xf7 && memcmp(header,hdr,6)==0 ){
        NSLog(@"isSysex: true");
        return true;
    }
    
    //NSLog(@"isSysex: false");
    return false;
}

- (NSArray*) parse:(NSData*) data {
    
    const char *bytes = [data bytes];
    NSMutableArray* ret = [NSMutableArray array];
    
    if (data.length > 11) {
        if ([self isSysex:data]){
            return nil;
        }
    }

    //Se non è un sysex, procedo nel processare il pacchetto.
    const int STATE_HDR = 0;
    const int STATE_TS = 1;
    const int STATE_ST = 2;
    const int STATE_D1 = 3;
    const int STATE_D2 = 4;

    int state = STATE_HDR;

    unsigned char status = 0;
    unsigned char channel = 0;
    unsigned char d1 = -1;
    unsigned char d2 = -1;

    for (int i = 0; i < data.length; i++) {
      unsigned char b = bytes[i];
      switch (state) {
        case STATE_HDR:
          state = STATE_TS;
          continue;
        case STATE_TS:
          state = STATE_ST;
          continue;
        case STATE_ST:
          status = b & 0xf0;
          channel = b & 0x0f;
          state = STATE_D1;
          continue;
        case STATE_D1:
          d1 = b;
          if (status < 0xC0 || status > 0xE0) {
            state = STATE_D2;
          } else {
            const unsigned char message[] = {status,channel,d1,d2};
            [ret addObject:[NSData dataWithBytes:message length: 4]];
            status = channel = 0;
            d1 = d2 = -1;
            state = STATE_TS;
          }
          continue;
        case STATE_D2:
          d2 = b;
          const unsigned char message[] = {status,channel,d1,d2};
          [ret addObject:[NSData dataWithBytes:message length: 4]];
          status = channel = 0;
          d1 = d2 = -1;
          state = STATE_TS;
          continue;

        default:
          NSLog(@"you should never reach this state!");
          break;
      }
    }

    return [ret copy];
  }

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
  //NSLog(@"SNTX didUpdateValueForCharacteristic %@", [peripheral.identifier UUIDString]);

  NSData* data = characteristic.value;

  //parse bytes
    NSArray* messages = [self parse:data];
    if (messages){
        //NSLog(@"SNTX didUpdateValueForCharacteristic uuid: %@", [characteristic.UUID fullUUIDString]);
        //Direct midi messages management
        for (NSData* data in messages){
            const char *m = [data bytes];
            unsigned char status = m[0];
            unsigned char ch = m[1];
            unsigned char d1 = m[2];
            unsigned char d2 = m[3];
            //NSLog(@"SNTX value:[status:%02x ch:%02x d1:%02x d2:%02x]", status, ch, d1, d2);
            
            if(status == 0x90 /*NoteON*/ || status == 0x80 /*NoteOFF*/ ||
                (status >= 0xb0 /*CC*/ && status < 0xc0 /*PrgChg*/ && (ch != 52 && ch != 53) /*filtering accelerometer y an z*/ ) ||
                (status >= 0xd0 /*ChPressure*/ && status < 0xe0 /*Bender*/)
               ){
                //NSLog(@"SNTX forwarding MidiMessage to Synth! status=%02x uuid=%@",status ,peripheral.identifier);
                switch(status){
                case 0x90:
                    [_midiSynth noteOnWithMacWithChannel:ch note:d1 velocity:d2 mac:[peripheral.identifier UUIDString]];
                    break;
                case 0x80:
                    [_midiSynth noteOffWithMacWithChannel:ch note:d1 velocity:d2 mac:[peripheral.identifier UUIDString]];
                    break;
                default:
                    if(status == 0xD0 /*aftertouch*/){
                      //print ("remapping aftertouch message ${msg.status} ${msg.d1} to Expression CC 0xB0 11 {msg.d1}" );
                      status = 0xB0;
                      int c = 60;
                      //d1=0x7f; //test
                      double v = c + ((127.0f-c)*d1)/127.0f;
                      //NSLog (@"xpression c=%d d1=%d => v=%lf (int)v=%d",c,d1,v,(int)v);
                      d2 = (int)v;
                      d1 = 11; //Expression CC
                    }
                    [_midiSynth midiEventWithMacWithCommand:(ch | status) d1:d1 d2:d2 mac:[peripheral.identifier UUIDString]];
                    break;
                }
            }
        }
    }
  //NORMAL flutter_blue management (SYSEX)
  //NSLog(@"SNTX uuid: %@ value: %@  len: %d ", [characteristic.UUID fullUUIDString], [characteristic value], (int)[characteristic.value length]);

  ProtosReadCharacteristicResponse *result = [[ProtosReadCharacteristicResponse alloc] init];
  [result setRemoteId:[peripheral.identifier UUIDString]];
  [result setCharacteristic:[self toCharacteristicProto:peripheral characteristic:characteristic]];
  [_channel invokeMethod:@"ReadCharacteristicResponse" arguments:[self toFlutterData:result]];

  // on iOS, this method also handles notification values
  ProtosOnCharacteristicChanged *onChangedResult = [[ProtosOnCharacteristicChanged alloc] init];
  [onChangedResult setRemoteId:[peripheral.identifier UUIDString]];
  [onChangedResult setCharacteristic:[self toCharacteristicProto:peripheral characteristic:characteristic]];
  [_channel invokeMethod:@"OnCharacteristicChanged" arguments:[self toFlutterData:onChangedResult]];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
  NSLog(@"didWriteValueForCharacteristic");
  ProtosWriteCharacteristicRequest *request = [[ProtosWriteCharacteristicRequest alloc] init];
  [request setRemoteId:[peripheral.identifier UUIDString]];
  [request setCharacteristicUuid:[characteristic.UUID fullUUIDString]];
  [request setServiceUuid:[characteristic.service.UUID fullUUIDString]];
  ProtosWriteCharacteristicResponse *result = [[ProtosWriteCharacteristicResponse alloc] init];
  [result setRequest:request];
  [result setSuccess:(error == nil)];
  [_channel invokeMethod:@"WriteCharacteristicResponse" arguments:[self toFlutterData:result]];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
  NSLog(@"didUpdateNotificationStateForCharacteristic");
  // Read CCC descriptor of characteristic
  CBDescriptor *cccd = [self findCCCDescriptor:characteristic];
  if(cccd == nil || error != nil) {
    // Send error
    ProtosSetNotificationResponse *response = [[ProtosSetNotificationResponse alloc] init];
    [response setRemoteId:[peripheral.identifier UUIDString]];
    [response setCharacteristic:[self toCharacteristicProto:peripheral characteristic:characteristic]];
    [response setSuccess:false];
    [_channel invokeMethod:@"SetNotificationResponse" arguments:[self toFlutterData:response]];
    return;
  }
  
  // Request a read
  [peripheral readValueForDescriptor:cccd];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
  ProtosReadDescriptorRequest *q = [[ProtosReadDescriptorRequest alloc] init];
  [q setRemoteId:[peripheral.identifier UUIDString]];
  [q setCharacteristicUuid:[descriptor.characteristic.UUID fullUUIDString]];
  [q setDescriptorUuid:[descriptor.UUID fullUUIDString]];
  if([descriptor.characteristic.service isPrimary]) {
    [q setServiceUuid:[descriptor.characteristic.service.UUID fullUUIDString]];
  } else {
    [q setSecondaryServiceUuid:[descriptor.characteristic.service.UUID fullUUIDString]];
    CBService *primaryService = [self findPrimaryService:[descriptor.characteristic service] peripheral:[descriptor.characteristic.service peripheral]];
    [q setServiceUuid:[primaryService.UUID fullUUIDString]];
  }
  ProtosReadDescriptorResponse *result = [[ProtosReadDescriptorResponse alloc] init];
  [result setRequest:q];
  int value = [descriptor.value intValue];
  [result setValue:[NSData dataWithBytes:&value length:sizeof(value)]];
  [_channel invokeMethod:@"ReadDescriptorResponse" arguments:[self toFlutterData:result]];

  // If descriptor is CCCD, send a SetNotificationResponse in case anything is awaiting
  if([descriptor.UUID.UUIDString isEqualToString:@"2902"]){
    ProtosSetNotificationResponse *response = [[ProtosSetNotificationResponse alloc] init];
    [response setRemoteId:[peripheral.identifier UUIDString]];
    [response setCharacteristic:[self toCharacteristicProto:peripheral characteristic:descriptor.characteristic]];
    [response setSuccess:true];
    [_channel invokeMethod:@"SetNotificationResponse" arguments:[self toFlutterData:response]];
  }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForDescriptor:(CBDescriptor *)descriptor error:(NSError *)error {
  ProtosWriteDescriptorRequest *request = [[ProtosWriteDescriptorRequest alloc] init];
  [request setRemoteId:[peripheral.identifier UUIDString]];
  [request setCharacteristicUuid:[descriptor.characteristic.UUID fullUUIDString]];
  [request setDescriptorUuid:[descriptor.UUID fullUUIDString]];
  if([descriptor.characteristic.service isPrimary]) {
    [request setServiceUuid:[descriptor.characteristic.service.UUID fullUUIDString]];
  } else {
    [request setSecondaryServiceUuid:[descriptor.characteristic.service.UUID fullUUIDString]];
    CBService *primaryService = [self findPrimaryService:[descriptor.characteristic service] peripheral:[descriptor.characteristic.service peripheral]];
    [request setServiceUuid:[primaryService.UUID fullUUIDString]];
  }
  ProtosWriteDescriptorResponse *result = [[ProtosWriteDescriptorResponse alloc] init];
  [result setRequest:request];
  [result setSuccess:(error == nil)];
  [_channel invokeMethod:@"WriteDescriptorResponse" arguments:[self toFlutterData:result]];
}

//
// Proto Helper methods
//
- (FlutterStandardTypedData*)toFlutterData:(GPBMessage*)proto {
  FlutterStandardTypedData *data = [FlutterStandardTypedData typedDataWithBytes:[[proto data] copy]];
  return data;
}

- (ProtosBluetoothState*)toBluetoothStateProto:(CBManagerState)state {
  ProtosBluetoothState *result = [[ProtosBluetoothState alloc] init];
  switch(state) {
    case CBManagerStateResetting:
      [result setState:ProtosBluetoothState_State_TurningOn];
      break;
    case CBManagerStateUnsupported:
      [result setState:ProtosBluetoothState_State_Unavailable];
      break;
    case CBManagerStateUnauthorized:
      [result setState:ProtosBluetoothState_State_Unauthorized];
      break;
    case CBManagerStatePoweredOff:
      [result setState:ProtosBluetoothState_State_Off];
      break;
    case CBManagerStatePoweredOn:
      [result setState:ProtosBluetoothState_State_On];
      break;
    default:
      [result setState:ProtosBluetoothState_State_Unknown];
      break;
  }
  return result;
}

- (ProtosScanResult*)toScanResultProto:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
  ProtosScanResult *result = [[ProtosScanResult alloc] init];
  [result setDevice:[self toDeviceProto:peripheral]];
  [result setRssi:[RSSI intValue]];
  ProtosAdvertisementData *ads = [[ProtosAdvertisementData alloc] init];
  [ads setConnectable:[advertisementData[CBAdvertisementDataIsConnectable] boolValue]];
  [ads setLocalName:advertisementData[CBAdvertisementDataLocalNameKey]];
  // Tx Power Level
  NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey];
  if(txPower != nil) {
    ProtosInt32Value *txPowerWrapper = [[ProtosInt32Value alloc] init];
    [txPowerWrapper setValue:[txPower intValue]];
    [ads setTxPowerLevel:txPowerWrapper];
  }
  // Manufacturer Specific Data
  NSData *manufData = advertisementData[CBAdvertisementDataManufacturerDataKey];
  if(manufData.length > 2) {
    unsigned short manufacturerId;
    [manufData getBytes:&manufacturerId length:2];
    [[ads manufacturerData] setObject:[manufData subdataWithRange:NSMakeRange(2, manufData.length - 2)] forKey:manufacturerId];
  }
  // Service Data
  NSDictionary *serviceData = advertisementData[CBAdvertisementDataServiceDataKey];
  for (CBUUID *uuid in serviceData) {
    [[ads serviceData] setObject:serviceData[uuid] forKey:uuid.UUIDString];
  }
  // Service Uuids
  NSArray *serviceUuids = advertisementData[CBAdvertisementDataServiceUUIDsKey];
  for (CBUUID *uuid in serviceUuids) {
    [[ads serviceUuidsArray] addObject:uuid.UUIDString];
  }
  [result setAdvertisementData:ads];
  return result;
}

- (ProtosBluetoothDevice*)toDeviceProto:(CBPeripheral *)peripheral {
  ProtosBluetoothDevice *result = [[ProtosBluetoothDevice alloc] init];
  [result setName:[peripheral name]];
  [result setRemoteId:[[peripheral identifier] UUIDString]];
  [result setType:ProtosBluetoothDevice_Type_Le]; // TODO: Does iOS differentiate?
  return result;
}

- (ProtosDeviceStateResponse*)toDeviceStateProto:(CBPeripheral *)peripheral state:(CBPeripheralState)state {
  ProtosDeviceStateResponse *result = [[ProtosDeviceStateResponse alloc] init];
  switch(state) {
    case CBPeripheralStateDisconnected:
      [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Disconnected];
      break;
    case CBPeripheralStateConnecting:
      [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Connecting];
      break;
    case CBPeripheralStateConnected:
      [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Connected];
      break;
    case CBPeripheralStateDisconnecting:
      [result setState:ProtosDeviceStateResponse_BluetoothDeviceState_Disconnecting];
      break;
  }
  [result setRemoteId:[[peripheral identifier] UUIDString]];
  return result;
}

- (ProtosDiscoverServicesResult*)toServicesResultProto:(CBPeripheral *)peripheral {
  ProtosDiscoverServicesResult *result = [[ProtosDiscoverServicesResult alloc] init];
  [result setRemoteId:[peripheral.identifier UUIDString]];
  NSMutableArray *servicesProtos = [NSMutableArray new];
  for(CBService *s in [peripheral services]) {
    [servicesProtos addObject:[self toServiceProto:peripheral service:s]];
  }
  [result setServicesArray:servicesProtos];
  return result;
}

- (ProtosConnectedDevicesResponse*)toConnectedDeviceResponseProto:(NSArray<CBPeripheral*>*)periphs {
  ProtosConnectedDevicesResponse *result = [[ProtosConnectedDevicesResponse alloc] init];
  NSMutableArray *deviceProtos = [NSMutableArray new];
  for(CBPeripheral *p in periphs) {
    [deviceProtos addObject:[self toDeviceProto:p]];
  }
  [result setDevicesArray:deviceProtos];
  return result;
}

- (ProtosBluetoothService*)toServiceProto:(CBPeripheral *)peripheral service:(CBService *)service  {
  ProtosBluetoothService *result = [[ProtosBluetoothService alloc] init];
  NSLog(@"peripheral uuid:%@", [peripheral.identifier UUIDString]);
  NSLog(@"   service uuid:%@", [service.UUID fullUUIDString]);
  [result setRemoteId:[peripheral.identifier UUIDString]];
  [result setUuid:[service.UUID fullUUIDString]];
  [result setIsPrimary:[service isPrimary]];
  
  // Characteristic Array
  NSMutableArray *characteristicProtos = [NSMutableArray new];
  for(CBCharacteristic *c in [service characteristics]) {
    [characteristicProtos addObject:[self toCharacteristicProto:peripheral characteristic:c]];
  }
  [result setCharacteristicsArray:characteristicProtos];
  
  // Included Services Array
  NSMutableArray *includedServicesProtos = [NSMutableArray new];
  for(CBService *s in [service includedServices]) {
    [includedServicesProtos addObject:[self toServiceProto:peripheral service:s]];
  }
  [result setIncludedServicesArray:includedServicesProtos];
  
  return result;
}

- (ProtosBluetoothCharacteristic*)toCharacteristicProto:(CBPeripheral *)peripheral characteristic:(CBCharacteristic *)characteristic {
  ProtosBluetoothCharacteristic *result = [[ProtosBluetoothCharacteristic alloc] init];
  [result setUuid:[characteristic.UUID fullUUIDString]];
  [result setRemoteId:[peripheral.identifier UUIDString]];
  [result setProperties:[self toCharacteristicPropsProto:characteristic.properties]];
  [result setValue:[characteristic value]];
  //NSLog(@"toCharacteristicProto uuid: %@ value: %@", [characteristic.UUID fullUUIDString], [characteristic value]);
  NSMutableArray *descriptorProtos = [NSMutableArray new];
  for(CBDescriptor *d in [characteristic descriptors]) {
    [descriptorProtos addObject:[self toDescriptorProto:peripheral descriptor:d]];
  }
  [result setDescriptorsArray:descriptorProtos];
  if([characteristic.service isPrimary]) {
    [result setServiceUuid:[characteristic.service.UUID fullUUIDString]];
  } else {
    // Reverse search to find service and secondary service UUID
    [result setSecondaryServiceUuid:[characteristic.service.UUID fullUUIDString]];
    CBService *primaryService = [self findPrimaryService:[characteristic service] peripheral:[characteristic.service peripheral]];
    [result setServiceUuid:[primaryService.UUID fullUUIDString]];
  }
  return result;
}

- (ProtosBluetoothDescriptor*)toDescriptorProto:(CBPeripheral *)peripheral descriptor:(CBDescriptor *)descriptor {
  ProtosBluetoothDescriptor *result = [[ProtosBluetoothDescriptor alloc] init];
  [result setUuid:[descriptor.UUID fullUUIDString]];
  [result setRemoteId:[peripheral.identifier UUIDString]];
  [result setCharacteristicUuid:[descriptor.characteristic.UUID fullUUIDString]];
  [result setServiceUuid:[descriptor.characteristic.service.UUID fullUUIDString]];
  int value = [descriptor.value intValue];
  [result setValue:[NSData dataWithBytes:&value length:sizeof(value)]];
  return result;
}

- (ProtosCharacteristicProperties*)toCharacteristicPropsProto:(CBCharacteristicProperties)props {
  ProtosCharacteristicProperties *result = [[ProtosCharacteristicProperties alloc] init];
  [result setBroadcast:(props & CBCharacteristicPropertyBroadcast) != 0];
  [result setRead:(props & CBCharacteristicPropertyRead) != 0];
  [result setWriteWithoutResponse:(props & CBCharacteristicPropertyWriteWithoutResponse) != 0];
  [result setWrite:(props & CBCharacteristicPropertyWrite) != 0];
  [result setNotify:(props & CBCharacteristicPropertyNotify) != 0];
  [result setIndicate:(props & CBCharacteristicPropertyIndicate) != 0];
  [result setAuthenticatedSignedWrites:(props & CBCharacteristicPropertyAuthenticatedSignedWrites) != 0];
  [result setExtendedProperties:(props & CBCharacteristicPropertyExtendedProperties) != 0];
  [result setNotifyEncryptionRequired:(props & CBCharacteristicPropertyNotifyEncryptionRequired) != 0];
  [result setIndicateEncryptionRequired:(props & CBCharacteristicPropertyIndicateEncryptionRequired) != 0];
  return result;
}

- (ProtosMtuSizeResponse*)toMtuSizeResponseProto:(CBPeripheral *)peripheral mtu:(uint32_t)mtu {
  ProtosMtuSizeResponse *result = [[ProtosMtuSizeResponse alloc] init];
  [result setRemoteId:[[peripheral identifier] UUIDString]];
  [result setMtu:mtu];
  return result;
}

- (void)log:(LogLevel)level format:(NSString *)format, ... {
  if(level <= _logLevel) {
    va_list args;
    va_start(args, format);
//    NSString* formattedMessage = [[NSString alloc] initWithFormat:format arguments:args];
    NSLog(format, args);
    va_end(args);
  }
}

- (uint32_t)getMtu:(CBPeripheral *)peripheral {
  if (@available(iOS 9.0, *)) {
    // Which type should we use? (issue #365)
    return (uint32_t)[peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
  } else {
    // Fallback to minimum on earlier versions. (issue #364)
    return 20;
  }
}

@end

@implementation FlutterBlueStreamHandler

- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
  self.sink = eventSink;
  return nil;
}

- (FlutterError*)onCancelWithArguments:(id)arguments {
  self.sink = nil;
  return nil;
}

@end

