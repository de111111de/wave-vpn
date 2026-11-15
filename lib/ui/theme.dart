import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens: aurora-glass on deep navy.
class W {
  static const bg = Color(0xFF05070F);
  static const surface = Color(0xFF0B1120);
  static const cyan = Color(0xFF00F2FE);
  static const blue = Color(0xFF4FACFE);
  static const violet = Color(0xFF7C5CFF);
  static const good = Color(0xFF34F5A5);
  static const warn = Color(0xFFFFC857);
  static const bad = Color(0xFFFF5C7A);
  static const grad = LinearGradient(colors: [cyan, blue]);
  static const gradFull = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [cyan, blue, violet]);
}

class WaveText {
  /// tabular numbers for speeds / timers
  static TextStyle num(double size, {Color? color, FontWeight w = FontWeight.w700}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: w, color: color);
}

class WaveTheme {
  static ThemeData dark() {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    final text = GoogleFonts.manropeTextTheme(base.textTheme).apply(bodyColor: Colors.white, displayColor: Colors.white);
    OutlineInputBorder border(Color c, [double w = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: c, width: w));
    return base.copyWith(
      scaffoldBackgroundColor: W.bg,
      colorScheme: const ColorScheme.dark(primary: W.cyan, secondary: W.blue, tertiary: W.violet, surface: W.surface, onPrimary: W.bg),
      textTheme: text,
      primaryTextTheme: text,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: Colors.white12,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.manrope(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: W.surface,
        showDragHandle: true,
        dragHandleColor: Colors.white24,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF111A2E),
        contentTextStyle: GoogleFonts.manrope(fontWeight: FontWeight.w600, color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: border(Colors.white12),
        enabledBorder: border(Colors.white12),
        focusedBorder: border(W.cyan, 1.5),
        hintStyle: const TextStyle(color: Colors.white38),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: W.cyan,
          foregroundColor: W.bg,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GoogleFonts.manrope(fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: W.cyan.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll(BorderSide(color: Colors.white.withValues(alpha: 0.10))),
          backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? W.cyan.withValues(alpha: 0.18) : Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? W.cyan : Colors.white70),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? W.bg : Colors.white70),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? W.cyan : Colors.white12),
      ),
    );
  }
}

// ───────────────────────── glass ─────────────────────────

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double radius;
  final bool glow;

  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.radius = 22, this.glow = false});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [if (glow) BoxShadow(color: W.cyan.withValues(alpha: 0.18), blurRadius: 30, spreadRadius: -4)],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white.withValues(alpha: 0.09), Colors.white.withValues(alpha: 0.025)],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap, borderRadius: r, child: Padding(padding: padding, child: child)),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── power button ─────────────────────────

class PowerButton extends StatefulWidget {
  final bool connected, connecting;
  final String elapsed;
  final VoidCallback onTap;
  const PowerButton({super.key, required this.connected, required this.connecting, required this.elapsed, required this.onTap});

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.connected, busy = widget.connecting;
    final label = on ? 'ПОДКЛЮЧЕНО' : (busy ? 'ЗАПУСК…' : 'СТАРТ');
    return Center(
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 270,
          height: 270,
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => CustomPaint(
              painter: _RingPainter(_c.value, on, busy),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutCubic,
                  width: 172,
                  height: 172,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.3, -0.4),
                      colors: on
                          ? [W.cyan.withValues(alpha: 0.55), const Color(0xFF0B1730)]
                          : [const Color(0xFF1B2640), const Color(0xFF080C18)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: on ? W.cyan.withValues(alpha: 0.5) : Colors.black54,
                        blurRadius: on ? 50 : 24,
                        spreadRadius: on ? 3 : 0,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(busy ? Icons.sync_rounded : Icons.power_settings_new_rounded, size: 58, color: on ? Colors.white : W.cyan),
                      const SizedBox(height: 8),
                      Text(label,
                          style: GoogleFonts.manrope(fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 1.8, color: on ? W.cyan : Colors.white70)),
                      const SizedBox(height: 3),
                      Text(widget.elapsed, style: WaveText.num(12, color: Colors.white54, w: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double t;
  final bool on, busy;
  _RingPainter(this.t, this.on, this.busy);

  @override
  void paint(Canvas c, Size s) {
    final ctr = s.center(Offset.zero);
    if (on) {
      for (var i = 0; i < 3; i++) {
        final p = (t + i / 3) % 1.0;
        c.drawCircle(
          ctr,
          92 + 42 * p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = W.cyan.withValues(alpha: (1 - p) * 0.35),
        );
      }
    }
    final rect = Rect.fromCircle(center: ctr, radius: 100);
    if (busy) {
      c.save();
      c.translate(ctr.dx, ctr.dy);
      c.rotate(t * 2 * pi);
      c.translate(-ctr.dx, -ctr.dy);
      c.drawArc(
        rect,
        0,
        pi * 1.4,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(startAngle: 0, endAngle: pi * 1.4, colors: [W.cyan.withValues(alpha: 0), W.blue, W.cyan]).createShader(rect),
      );
      c.restore();
    } else {
      c.drawCircle(
        ctr,
        100,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = on ? 2.5 : 1.5
          ..color = (on ? W.cyan : Colors.white).withValues(alpha: on ? 0.85 : 0.12),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter o) => o.t != t || o.on != on || o.busy != busy;
}

// ───────────────────────── top bar & dock ─────────────────────────

class WaveTopBar extends StatelessWidget {
  final bool connected, connecting;
  final VoidCallback onScan, onAdd;
  const WaveTopBar({super.key, required this.connected, required this.connecting, required this.onScan, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final label = connected ? 'Защищено' : (connecting ? 'Подключение…' : 'Не защищено');
    final dot = connected ? W.good : (connecting ? W.warn : Colors.white30);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: W.gradFull,
              boxShadow: [BoxShadow(color: W.cyan.withValues(alpha: connected ? 0.55 : 0.22), blurRadius: 18)],
            ),
            child: const Icon(Icons.waves_rounded, color: W.bg, size: 25),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (r) => W.grad.createShader(r),
                child: Text('Wave', style: GoogleFonts.manrope(fontSize: 23, fontWeight: FontWeight.w800, color: Colors.white, height: 1.1)),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot,
                      boxShadow: [if (connected) BoxShadow(color: dot.withValues(alpha: 0.8), blurRadius: 8)],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: GoogleFonts.manrope(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.white60)),
                ],
              ),
            ],
          ),
          const Spacer(),
          _TopBtn(Icons.qr_code_scanner_rounded, 'Сканировать QR', onScan),
          const SizedBox(width: 8),
          _TopBtn(Icons.add_rounded, 'Добавить подписку', onAdd),
        ],
      ),
    );
  }
}

class _TopBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const _TopBtn(this.icon, this.tip, this.onTap);

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: Material(
          color: Colors.white.withValues(alpha: 0.06),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(width: 42, height: 42, child: Icon(icon, color: W.cyan, size: 22)),
          ),
        ),
      );
}

class WaveDock extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;
  final List<(IconData, String)> items;
  const WaveDock({super.key, required this.index, required this.onChanged, required this.items});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Container(
              height: 68,
              decoration: BoxDecoration(
                color: const Color(0xFF0B1120).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          margin: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(21),
                            gradient: i == index
                                ? LinearGradient(colors: [W.cyan.withValues(alpha: 0.22), W.violet.withValues(alpha: 0.16)])
                                : null,
                            border: i == index ? Border.all(color: W.cyan.withValues(alpha: 0.35)) : null,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(items[i].$1, size: 22, color: i == index ? W.cyan : Colors.white54),
                              const SizedBox(height: 3),
                              Text(items[i].$2,
                                  style: GoogleFonts.manrope(
                                      fontSize: 10.5, fontWeight: i == index ? FontWeight.w800 : FontWeight.w600, color: i == index ? W.cyan : Colors.white54)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
