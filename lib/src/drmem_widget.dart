/// Provides a widget to interact with a DrMem node through the client API.
///
/// Near the top of your widget tree, you place an instance of [DrMem]. This
/// widget should be rebuilt as infrequently as possible. It contains a table
/// of known nodes and it maintains connections to them. If this widget gets
/// rebuilt, all of that state needs to be reproduced and will cause jank and
/// extra work on the DrMem node.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nsd/nsd.dart';
import 'package:dart_drmem/dart_drmem.dart';

import 'dart:developer' as dev;

typedef _NodeMap = Map<String, DrMemService>;

/// Exception thrown when an operation is requested on a DrMem node that is
/// not currently connected or registered.
class DrMemNodeError implements Exception {
  final String message;
  DrMemNodeError(this.message);
  @override
  String toString() => "DrMemNodeError: $message";
}

// Removes a trailing period. Under OSX, a local hostname is given as
// "name.local." so we need to remove the trailing period.

String _stripTrailingPeriod(String s) =>
    s.endsWith(".") ? s.substring(0, s.length - 1) : s;

extension on Service {
  // Looks in the `txt` field of the Service info for a value associated with
  // the requested key. If found, it returns the value as a String.

  String? _propToString(String key) {
    final Uint8List? tmp = txt?[key];

    return tmp != null
        ? const Utf8Decoder(allowMalformed: true).convert(tmp)
        : null;
  }

  HostInfo _chooseHost(int port, String name, List<InternetAddress> ips) {
    if (ips.isNotEmpty) {
      return HostInfo(ips.first.address, port);
    } else {
      return HostInfo(_stripTrailingPeriod(name), port);
    }
  }

  NodeInfo? toNodeInfo(bool active) {
    if (this case Service(
      name: String n,
      host: String h,
      port: int p,
      addresses: List<InternetAddress> addrs,
    )) {
      dev.log("node announcement: $this", name: "mDNS");

      final addr =
          HostInfo.tryParse(_propToString("pref-addr")) ??
          _chooseHost(p, h, addrs);
      final boottime = _propToString("bootTime");

      (String, String)? sigs;

      // This was added for backwards compatibility. DrMem v0.5.0, and earlier,
      // only reported the SHA-1 digest of the certificate. Later versions
      // report two digests to make it much more difficult to generate a
      // fake certificate.

      final tmp = _propToString("signature");

      if (tmp == null) {
        final s1 = _propToString("sig_md5");
        final s2 = _propToString("sig_sha");

        if (s1 != null && s2 != null) {
          sigs = (s1, s2);
        }
      } else {
        sigs = ("", tmp);
      }

      final ni = NodeInfo(
        name: n,
        addr: addr,
        location: _propToString("location") ?? "unknown",
        version: _propToString("version") ?? "0.0.0",
        bootTime: active
            ? (boottime != null
                  ? DateTime.tryParse(boottime) ?? DateTime.now()
                  : DateTime.now())
            : null,
        signatures: sigs,
        queries: _propToString("queries") ?? "/drmem/q",
        mutations: _propToString("mutations") ?? "/drmem/q",
        subscriptions: _propToString("subscriptions") ?? "/drmem/s",
      );

      dev.log("parsed node: $ni", name: "mDNS");
      return ni;
    } else {
      dev.log("couldn't convert $this to NodeInfo", name: "mDNS");
      return null;
    }
  }
}

/// The [DrMem] widget implements a "provider" widget for an application's
/// tree. Its state manages GraphQL connections to registered DrMem nodes. It
/// should be located near the top of the tree so it remains stable during the
/// life of the application.

class DrMem extends StatefulWidget {
  final Widget child;

  /// Creates an instance of the [DrMem] widget.
  ///
  /// This widget provides methods to communicate with a DrMem node. Some of
  /// these connections are long-lived (receiving device values, for instance)
  /// so this widget should be placed near the top of the widget tree to
  /// prevent it from tearing down and rebuilding the connections.
  ///
  /// [key] is an optional key to be associated with the widget
  ///
  /// [child] is the widget subtree under this widget.

  const DrMem({required this.child, super.key});

  @override
  State<DrMem> createState() => _DrMemState();

  /// Returns the instance of this class higher up in the widget tree.

  static _DrMemState _of(BuildContext context) =>
      context.findAncestorStateOfType<_DrMemState>()!;

  /// Returns a future that resolves to a stream that returns NodeInfo objects
  /// for DrMem nodes that are announcing themselves on the local network. The
  /// future only blocks early in the application's lifetime, when the mDNS
  /// service is initializing. Once that is done, the Future resolves
  /// immediately.
  ///
  /// [context] is the context of the widget making the request.

  static Stream<NodeInfo> mdnsSubscribe(BuildContext context) =>
      _of(context)._mdnsSubscribe;

  /// Adds a mapping of a node to its network connections. The `NodeInfo` type
  /// provides information on how the connections should be made.
  ///
  /// [context] is the context of the widget making the request.
  ///
  /// [info] specifies the information of the node to be added.
  ///
  /// [clientID] is a unique string to identify an instance of a GraphQL client.
  /// An application should provide a way to view this value so it can be
  /// specified in the site's `drmem.toml` file. This value should not be
  /// available publicly but should only be known to the DrMem targets.

  static void addNode(BuildContext context, NodeInfo info, ClientID clientID) =>
      _of(context)._addNode(info, clientID);

  /// Removes a node from the table.
  ///
  /// [context] is the context of the widget making the request.
  ///
  /// [name] is the name of the node. All DrMem nodes should have unique names.

  static void removeNode(BuildContext context, String name) =>
      _of(context)._removeNode(name);

  /// Sets a value of a DrMem device.
  ///
  /// The target device must be settable.
  ///
  /// [context] is the context of the widget making the request.
  ///
  /// [device] is the name fo the device.
  ///
  /// [value] is the value to set. Most devices enforce a value type. For
  /// instance, "enable" devices are typically boolean. If the incorrect type
  /// is sent, the driver will return an error. See the driver documentation
  /// to see what data type is supported by the device.
  ///
  /// The function returns a [Reading] structure echoing the setting used by
  /// the driver and containing the timestamp of when the setting was applied.
  /// Some drivers will return an error when a setting value is out of range.
  /// Other drivers may accept the value, but clip it to remain in range. See
  /// the driver docs to understand the behavior since the returned value may
  /// differ from the one sent.

  static Future<Reading> setDevice(
    BuildContext context,
    String node,
    Device device,
    DevValue value,
  ) => _of(context)._setDevice(node, device, value);

  /// Retrieves driver information from a DrMem node.
  ///
  /// Each instance of DrMem interacts with it own set of hardware devices and,
  /// therefore, is built with a custom set of drivers. This function queries
  /// the node for available information on its set of drivers. If the node is
  /// not registered, this request returns `null`.
  ///
  /// [context] is the context of the widget making the request.
  ///
  /// [node] is the name of the DrMem node used when registering it with
  /// [addNode].

  static Future<List<DriverInfo>> getDriverInfo(
    BuildContext context,
    String node,
  ) => _of(context)._getDriverInfo(node);

  /// Returns information about a device.
  ///
  /// [context] is the context of the widget making the request.
  ///
  /// [node] indicates which DrMem node should be queried.
  ///
  /// [device] specifies which device's information should be returned. If a
  /// unique, existing device name is given, a one-element `List` will be
  /// returned. If the device parameter specifies a pattern, all matching
  /// devices will have their information returned.
  ///
  /// Returns a Future that resolves to a `List` of device information
  /// ([DevInfo]), or an error.

  static Future<List<DeviceInfo>> getDeviceInfo(
    BuildContext context, {
    required String node,
    required DeviceLike device,
  }) => _of(context)._getDeviceInfo(node, device);

  /// Returns a stream of readings for a device.
  ///
  /// This method provides many flexible ways to obtain device readings. Some
  /// of these options may be limited, if the DrMem node is using the simple
  /// backend (which only saves one point of history.)
  ///
  /// [context] is the context of the widget making the request.
  ///
  /// [device] is the device whose readings should be streamed.
  ///
  /// [startTime] and [endTime] are optional arguments which create a range
  /// of time in which readings should be returned. If both are `null`, the
  /// latest and all future readings are returned until the stream is closed.
  /// If `startTime` is null, the latest reading is returned and all future
  /// readings until `endTime` is reached. If `endTime` is null, then all
  /// readings from `startTime` until the current time are returned followed
  /// by all future readings until the stream is closed. If both times are
  /// before the current time, just the data between the two times is returned.
  /// If both times are after the current time, then readings won't begin until
  /// `startTime` is reached.
  ///
  /// DrMem's configuration determines the size of a device's history. This
  /// function can only return what's available.

  static Stream<Reading> monitorDevice(
    BuildContext context,
    String node,
    Device device, {
    DateTime? startTime,
    DateTime? endTime,
  }) => _of(context)._monitorDevice(node, device, startTime, endTime);
}

class _DrMemState extends State<DrMem> {
  late Future<Discovery> _disc;
  final _NodeMap _nodes = {};

  @override
  void initState() {
    super.initState();
    dev.log("starting mDNS monitor", name: "mdns.announce");
    _disc = startDiscovery('_drmem._tcp', ipLookupType: IpLookupType.v4);
  }

  @override
  void dispose() {
    Future.microtask(() async {
      final tmp = await _disc;

      await stopDiscovery(tmp);
      dev.log("stopped mDNS monitor", name: "mDNS");
    });

    // Close the connections to DrMem.

    for (final MapEntry(value: v) in _nodes.entries) {
      v.dispose();
    }
    super.dispose();
  }

  // Subscribes to the mDNS service to receive announcements for changes of
  // the state of DrMem nodes on the local network.

  Stream<NodeInfo> get _mdnsSubscribe {
    // Set up a stream controller so we can announce updates about DrMem nodes.
    // We use a broadcast stream so multiple widgets can subscribe to the same
    // discovery stream if needed.

    final StreamController<NodeInfo> ctrl = StreamController();

    // Set up a listener to receive mDNS announcements. When an announcement is
    // received, the listener parses the announcement and adds it to the stream
    // if it is valid.

    void serviceListener(Service service, ServiceStatus status) {
      if (service.name == null) {
        dev.log(
          "mDNS announcement is missing service name ... ignoring",
          name: "mDNS",
        );
        return;
      }

      final ni = service.toNodeInfo(status == ServiceStatus.found);

      if (ni != null) {
        ctrl.add(ni);
        dev.log("announced node ${ni.name}", name: "mDNS");
      }
    }

    // Define handlers that start and stop listening to the mDNS service
    // during application lifecycle events.

    ctrl.onResume = ctrl.onListen = () async {
      final mdns = await _disc;
      mdns.addServiceListener(serviceListener);
      dev.log("listening to mdns stream", name: "mDNS");
    };

    ctrl.onPause = ctrl.onCancel = () async {
      final mdns = await _disc;
      mdns.removeServiceListener(serviceListener);
      dev.log("ignoring mdns stream", name: "mDNS");
    };

    // Return the stream of node announcements.

    return ctrl.stream;
  }

  // The implementation of [DrMem.addNode].

  void _addNode(NodeInfo info, ClientID clientId) {
    if (!_nodes.containsKey(info.name)) {
      _nodes[info.name] = DrMemService(info: info, clientId: clientId);
    } else {
      dev.log(
        "attempted to add node ${info.name} but it already exists ... ignoring",
        name: "DrMem",
      );
    }
  }

  // The implementation of [DrMem.removeNode].

  void _removeNode(String name) => _nodes.remove(name);

  // Helper to retrieve a node or throw if missing.

  DrMemService _getNodeOrThrow(String node) =>
      _nodes[node] ??
      (throw DrMemNodeError("DrMem node '$node' is not connected."));

  Future<Reading> _setDevice(
    String node,
    Device device,
    DevValue value,
  ) async => _getNodeOrThrow(node).setDevice(device, value);

  Future<List<DriverInfo>> _getDriverInfo(String node) async =>
      _getNodeOrThrow(node).getDriverInfo();

  Future<List<DeviceInfo>> _getDeviceInfo(
    String node,
    DeviceLike device,
  ) async => switch (device) {
    DevicePattern() => _getNodeOrThrow(node).getDeviceInfo(device: device),
    Device() => _getNodeOrThrow(node).getDeviceInfo(device: device.toPattern()),
  };

  Stream<Reading> _monitorDevice(
    String node,
    Device device,
    DateTime? startTime,
    DateTime? endTime,
  ) async* {
    yield* _getNodeOrThrow(
      node,
    ).monitorDevice(device, startTime: startTime, endTime: endTime);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
