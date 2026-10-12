import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool autoFocus;
  final FocusNode? focusNode;
  final Color? normalBackgroundColor;
  final Color? normalBorderColor;
  final Color? focusedBackgroundColor;
  final Color? focusedBorderColor;
  final double? focusedBorderWidth;
  final double? scaleFactor;

  const TvFocusable({
    super.key,
    required this.child,
    required this.onTap,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
    this.borderRadius,
    this.padding,
    this.margin,
    this.autoFocus = false,
    this.focusNode,
    this.normalBackgroundColor,
    this.normalBorderColor,
    this.focusedBackgroundColor,
    this.focusedBorderColor,
    this.focusedBorderWidth,
    this.scaleFactor,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late final FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _isFocused = _focusNode.hasFocus;
    _focusNode.addListener(_onFocusChange);
    _focusNode.onKeyEvent = (node, event) {
      final isDown = event is KeyDownEvent;
      final isRepeat = event is KeyRepeatEvent;

      if (isDown || isRepeat) {
        if (isDown &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonSelect ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          debugPrint('[TV_KEY] SELECT triggered onTap()!');
          widget.onTap();
          return KeyEventResult.handled;
        }
        // Allow both KeyDown and KeyRepeat for continuous Left/Right seeking
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft && widget.onLeft != null) {
          widget.onLeft!();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight && widget.onRight != null) {
          widget.onRight!();
          return KeyEventResult.handled;
        }
        if (isDown && event.logicalKey == LogicalKeyboardKey.arrowUp && widget.onUp != null) {
          widget.onUp!();
          return KeyEventResult.handled;
        }
        if (isDown && event.logicalKey == LogicalKeyboardKey.arrowDown && widget.onDown != null) {
          widget.onDown!();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void didUpdateWidget(TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      } else {
        _focusNode.removeListener(_onFocusChange);
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_onFocusChange);
    }
    _isFocused = _focusNode.hasFocus;
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_onFocusChange);
    }
    super.dispose();
  }

  void _onFocusChange() {
    if (mounted) {
      final hasFocus = _focusNode.hasFocus;
      setState(() => _isFocused = hasFocus);
      debugPrint('[TV_FOCUS] hasFocus=$hasFocus');
      if (hasFocus) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 150),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(8);

    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autoFocus,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          margin: widget.margin,
          padding: widget.padding,
          transform: _isFocused && widget.scaleFactor != null
              ? Matrix4.diagonal3Values(widget.scaleFactor!, widget.scaleFactor!, 1.0)
              : null,
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: _isFocused
                ? (widget.focusedBackgroundColor ?? const Color(0xFF0D7FF2).withValues(alpha: 0.28))
                : (widget.normalBackgroundColor ?? Colors.transparent),
            border: Border.all(
              color: _isFocused
                  ? (widget.focusedBorderColor ?? const Color(0xFF0D7FF2))
                  : (widget.normalBorderColor ?? Colors.transparent),
              width: _isFocused ? (widget.focusedBorderWidth ?? 2.5) : 1.0,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: (widget.focusedBorderColor ?? const Color(0xFF0D7FF2)).withValues(alpha: 0.55),
                      blurRadius: 16,
                      spreadRadius: 3,
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
