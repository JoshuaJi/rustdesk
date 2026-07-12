import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart' show gFFI;
import 'package:get/get.dart';

/// iOS native bridge for claiming hardware-keyboard shortcuts from iPadOS
/// and forwarding them to the remote peer via [InputModel].
///
/// Channel: `org.rustdesk.rustdesk/ios_keyboard`
/// Native methods:
///   - setCaptureSystemShortcuts(bool)
///   - getCaptureSystemShortcuts() -> bool
/// Native events:
///   - onHardwareKey { usbHid: int, down: bool, characters: String }
class IosHardwareKeyboard {
  IosHardwareKeyboard._();

  static final IosHardwareKeyboard instance = IosHardwareKeyboard._();

  static const _channel = MethodChannel('org.rustdesk.rustdesk/ios_keyboard');

  /// Whether native capture is currently requested (UI toggle / session).
  final captureEnabled = false.obs;

  bool _handlerInstalled = false;
  InputModel? _inputModel;

  /// Attach to a remote session's [InputModel]. Enables capture by default on iOS.
  Future<void> attachSession(InputModel inputModel,
      {bool enable = true}) async {
    if (!isIOS) return;
    _inputModel = inputModel;
    _installHandler();
    if (enable) {
      await setCaptureSystemShortcuts(true);
    }
  }

  /// Detach and release system shortcut capture.
  Future<void> detachSession() async {
    if (!isIOS) return;
    await setCaptureSystemShortcuts(false);
    _inputModel = null;
  }

  Future<void> setCaptureSystemShortcuts(bool enabled) async {
    if (!isIOS) return;
    _installHandler();
    try {
      await _channel.invokeMethod('setCaptureSystemShortcuts', enabled);
      captureEnabled.value = enabled;
    } catch (e) {
      debugPrint('IosHardwareKeyboard.setCaptureSystemShortcuts failed: $e');
    }
  }

  Future<bool> getCaptureSystemShortcuts() async {
    if (!isIOS) return false;
    try {
      final v = await _channel.invokeMethod<bool>('getCaptureSystemShortcuts');
      captureEnabled.value = v ?? false;
      return captureEnabled.value;
    } catch (e) {
      debugPrint('IosHardwareKeyboard.getCaptureSystemShortcuts failed: $e');
      return false;
    }
  }

  void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onHardwareKey') {
        final args = call.arguments;
        if (args is Map) {
          _onNativeKey(
            usbHid: (args['usbHid'] as num?)?.toInt() ?? 0,
            down: args['down'] == true,
            characters: (args['characters'] as String?) ?? '',
          );
        }
      }
      return null;
    });
  }

  void _onNativeKey({
    required int usbHid,
    required bool down,
    required String characters,
  }) {
    final model = _inputModel ?? gFFI.inputModel;
    if (model.isViewOnly || model.isViewCamera) return;
    if (usbHid == 0) return;

    // Reuse mobile dedupe: native may fire both UIKeyCommand and presses.
    // newKeyboardMode path is the iOS map mode used for physical keys.
    final character = characters.isNotEmpty ? characters : '';
    model.newKeyboardMode(character, usbHid & 0xFFFF, down, false);
  }
}
