import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:uuid/uuid.dart';


class OrderDetailsPage extends StatefulWidget {
  final String orderId;

  OrderDetailsPage({required this.orderId});

  @override
  _OrderDetailsPageState createState() => _OrderDetailsPageState();
}

class _OrderDetailsPageState extends State<OrderDetailsPage> {
  final String deliveryManId = const Uuid().v4();
  GoogleMapController? _mapController;
  MqttServerClient? _client;
  bool _isConnected = false;
  LatLng? _currentPosition;
  Timer? _locationTimer;
  final String _mqttBroker = 'test.mosquitto.org';
  final int _mqttPort = 1883;
  late final String _mqttTopic;

  @override
  void initState() {
    super.initState();
    _mqttTopic = 'delivery_locations/${widget.orderId}';
    _checkPermissionsAndGetLocation();
    _setupMqttClient();
  }

  Future<void> _checkPermissionsAndGetLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      return;
    }

    _startLocationUpdates();
  }

  void _startLocationUpdates() {
    _getCurrentLocation(); // Get initial location
    _locationTimer = Timer.periodic(Duration(seconds: 30), (_) {
      _getCurrentLocation();
    });
  }

  Future<void> _setupMqttClient() async {
    _client = MqttServerClient(_mqttBroker, 'flutter_client_$deliveryManId');
    _client!.port = _mqttPort;
    _client!.keepAlivePeriod = 20;
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.logging(on: true);

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('flutter_client_$deliveryManId')
        .withWillTopic('willtopic')
        .withWillMessage('Delivery man disconnected')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    _client!.connectionMessage = connMessage;

    try {
      await _client!.connect();
    } catch (e) {
      print('Exception: $e');
      _reconnect();
    }
  }

  void _onConnected() {
    print('MQTT client connected');
    setState(() {
      _isConnected = true;
    });
  }

  void _onDisconnected() {
    print('MQTT client disconnected');
    setState(() {
      _isConnected = false;
    });
    _reconnect();
  }

  void _reconnect() {
    print('Reconnecting to MQTT broker...');
    Future.delayed(Duration(seconds: 5), () {
      _setupMqttClient();
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });

      if (_mapController != null && _currentPosition != null) {
        _mapController!.animateCamera(
          CameraUpdate.newLatLng(_currentPosition!),
        );
      }

      _publishLocationToMqtt();
    } catch (e) {
      print('Error getting location: $e');
    }
  }

  Future<void> _publishLocationToMqtt() async {
    if (_currentPosition != null && _isConnected) {
      final locationJson = json.encode({
        'deliveryManId': deliveryManId,
        'orderId': widget.orderId,
        'latitude': _currentPosition!.latitude,
        'longitude': _currentPosition!.longitude,
        'timestamp': DateTime.now().toIso8601String(),
      });

      final builder = MqttClientPayloadBuilder();
      builder.addString(locationJson);

      _client!.publishMessage(_mqttTopic, MqttQos.atLeastOnce, builder.payload!);
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    if (_currentPosition != null) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_currentPosition!, 15),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Delivery Order Details'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('orders').doc(widget.orderId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return Center(child: Text('Order not found'));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          return SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Order #${widget.orderId}', 
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                SizedBox(height: 16),
                _buildDetailItem('Customer', data['customerName']),
                _buildDetailItem('Address', data['address']),
                _buildDetailItem('Phone', data['phone']),
                _buildDetailItem('Email', data['email']),

                _buildDetailItem('Status', data['status']),
                Divider(),
                SizedBox(height: 16),
                Text('Products:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ...(data['products'] as List<dynamic>).map((product) => Text('- $product')),
                Divider(),
                SizedBox(height: 16),
                Text('Total Price: ₹${data['totalPrice']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                SizedBox(height: 16),
                Container(
                  height: 300,
                  child: _currentPosition == null
                      ? Center(child: CircularProgressIndicator())
                      : GoogleMap(
                          onMapCreated: _onMapCreated,
                          initialCameraPosition: CameraPosition(
                            target: _currentPosition!,
                            zoom: 15,
                          ),
                          markers: {
                            Marker(
                              markerId: MarkerId('currentLocation'),
                              position: _currentPosition!,
                              infoWindow: InfoWindow(
                                title: 'Current Location',
                                snippet: 'Delivery in progress',
                              ),
                            ),
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _getCurrentLocation,
        child: Icon(Icons.location_searching),
        tooltip: 'Update Location',
      ),
    );
  }

  Widget _buildDetailItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text('$label:', 
              style: TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _updateOrderStatus(String currentStatus) async {
    String newStatus;
    switch (currentStatus) {
      case 'pending':
        newStatus = 'processing';
        break;
      case 'processing':
        newStatus = 'out_for_delivery';
        break;
      case 'out_for_delivery':
        newStatus = 'delivered';
        break;
      default:
        newStatus = currentStatus;
    }

    try {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(widget.orderId)
          .update({
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
        'lastLocation': _currentPosition != null
            ? GeoPoint(_currentPosition!.latitude, _currentPosition!.longitude)
            : null,
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order status updated successfully')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to update order status')));
    }
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _mapController?.dispose();
    _client?.disconnect();
    super.dispose();
  }
}