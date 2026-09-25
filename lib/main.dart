import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math' as math;

void main() => runApp(const OrthogonalCheckersApp());

class OrthogonalCheckersApp extends StatelessWidget {
  const OrthogonalCheckersApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.brown),
      home: const GamePage(),
    );
  }
}

enum AIDiff { easy, medium, hard, expert, master }

class GameState {
  List<List<int>> board;
  int turn, wc, bc;
  GameState(this.board, this.turn, this.wc, this.bc);
}

class Move {
  int fromR, fromC, toR, toC;
  int? capR, capC;
  Move(this.fromR, this.fromC, this.toR, this.toC, this.capR, this.capC);
  bool get isCapture => capR != null;
}

class GamePage extends StatefulWidget {
  const GamePage({super.key});
  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  late List<List<int>> board;
  int turn = 1;
  int? selR, selC;

  // Drives the per-cell pop animation: only the square a piece just landed
  // on gets a fresh key, so only it replays the pop-in tween.
  int _moveSeq = 0;
  int? _lastToR, _lastToC;

  List<Move> legalMoves = [];
  List<Move> chainMoves = [];
  bool mandatoryCapture = true;
  bool vsAI = true;
  bool chainMode = false;
  int whiteCaps = 0, blackCaps = 0, whiteWins = 0, blackWins = 0;
  List<GameState> history = [];
  AIDiff diff = AIDiff.hard;
  final AudioPlayer _movePlayer = AudioPlayer();
  final AudioPlayer _capturePlayer = AudioPlayer();
  final AudioPlayer _winPlayer = AudioPlayer();
  final math.Random rand = math.Random();
  final dirs = const [
    [-1, 0],
    [1, 0],
    [0, -1],
    [0, 1]
  ];

  @override
  void initState() {
    super.initState();
    reset();
    loadScore();
  }

  @override
  void dispose() {
    _movePlayer.dispose();
    _capturePlayer.dispose();
    _winPlayer.dispose();
    super.dispose();
  }

  Future<void> loadScore() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      whiteWins = p.getInt('wWins') ?? 0;
      blackWins = p.getInt('bWins') ?? 0;
    });
  }

  Future<void> saveScore() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('wWins', whiteWins);
    await p.setInt('bWins', blackWins);
  }

  Future<void> _playSound(String asset, AudioPlayer player) async {
    try {
      await player.stop();
      await player.play(AssetSource('sounds/$asset'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sound error: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void playMoveSound() => _playSound('move.wav', _movePlayer);
  void playCaptureSound() => _playSound('capture.wav', _capturePlayer);
  void playWinSound() => _playSound('win.wav', _winPlayer);

  void reset() {
    board = List.generate(5, (_) => List.filled(5, 0));
    for (int c = 0; c < 5; c++) {
      board[0][c] = 1;
      board[1][c] = 1;
      board[3][c] = 2;
      board[4][c] = 2;
    }
    board[2][0] = 1;
    board[2][1] = 1;
    board[2][3] = 2;
    board[2][4] = 2;
    turn = 1;
    selR = null;
    selC = null;
    _moveSeq = 0;
    _lastToR = null;
    _lastToC = null;
    legalMoves = [];
    chainMoves = [];
    chainMode = false;
    whiteCaps = 0;
    blackCaps = 0;
    history = [];
    setState(() {});
  }

  List<List<int>> clone(List<List<int>> b) =>
      b.map((r) => List<int>.from(r)).toList();

  List<Move> capsFrom(int r, int c, List<List<int>> b) {
    List<Move> caps = [];
    int pl = b[r][c];
    if (pl == 0) return caps;
    int en = pl == 1 ? 2 : 1;
    for (var d in dirs) {
      int er = r + d[0], ec = c + d[1];
      int lr = r + d[0] * 2, lc = c + d[1] * 2;
      if (er >= 0 &&
          er < 5 &&
          ec >= 0 &&
          ec < 5 &&
          lr >= 0 &&
          lr < 5 &&
          lc >= 0 &&
          lc < 5) {
        if (b[er][ec] == en && b[lr][lc] == 0) {
          caps.add(Move(r, c, lr, lc, er, ec));
        }
      }
    }
    return caps;
  }

  List<Move> allMoves(int pl, List<List<int>> b) {
    List<Move> caps = [], moves = [];
    for (int r = 0; r < 5; r++) {
      for (int c = 0; c < 5; c++) {
        if (b[r][c] == pl) {
          for (var d in dirs) {
            int nr = r + d[0], nc = c + d[1];
            if (nr >= 0 && nr < 5 && nc >= 0 && nc < 5 && b[nr][nc] == 0) {
              moves.add(Move(r, c, nr, nc, null, null));
            }
          }
          caps.addAll(capsFrom(r, c, b));
        }
      }
    }
    if (mandatoryCapture && caps.isNotEmpty) return caps;
    return [...caps, ...moves];
  }

  List<Move> getAllMoves(int pl) => allMoves(pl, board);

  void pushH() {
    history.add(GameState(clone(board), turn, whiteCaps, blackCaps));
    if (history.length > 100) history.removeAt(0);
  }

  void undo() {
    if (history.isEmpty || chainMode) return;
    var last = history.removeLast();
    setState(() {
      board = last.board;
      turn = last.turn;
      whiteCaps = last.wc;
      blackCaps = last.bc;
      selR = null;
      selC = null;
      legalMoves = [];
      chainMode = false;
      chainMoves = [];
      _lastToR = null;
      _lastToC = null;
    });
  }

  void onTap(int r, int c) {
    if (chainMode) {
      for (var m in chainMoves) {
        if (m.toR == r && m.toC == c) {
          doMove(m, isChainCont: true);
          return;
        }
      }
      return;
    }
    if (board[r][c] == turn) {
      setState(() {
        selR = r;
        selC = c;
        var all = getAllMoves(turn);
        legalMoves = all.where((m) => m.fromR == r && m.fromC == c).toList();
      });
      return;
    }
    for (var m in legalMoves) {
      if (m.toR == r && m.toC == c) {
        doMove(m, isChainCont: false);
        return;
      }
    }
  }

  /// Applies a move and resolves ALL of its consequences (capture removal,
  /// chain-capture detection, win/draw detection, turn switching) in a
  /// single synchronous update. Nothing about move legality or the next
  /// legal-move highlight is ever delayed, so there's no window where a
  /// tap on the correct square can be silently dropped.
  void doMove(Move m, {required bool isChainCont}) {
    if (!isChainCont) pushH();

    bool triggerAiContinue = false;
    bool triggerAiNext = false;
    int? pendingWinner;
    bool pendingDraw = false;

    setState(() {
      board[m.toR][m.toC] = board[m.fromR][m.fromC];
      board[m.fromR][m.fromC] = 0;
      _moveSeq++;
      _lastToR = m.toR;
      _lastToC = m.toC;

      bool wasCap = false;
      if (m.isCapture) {
        board[m.capR!][m.capC!] = 0;
        wasCap = true;
        if (turn == 1) {
          whiteCaps++;
        } else {
          blackCaps++;
        }
      }

      if (wasCap) {
        playCaptureSound();
        var nxt = capsFrom(m.toR, m.toC, board);
        if (nxt.isNotEmpty) {
          chainMode = true;
          selR = m.toR;
          selC = m.toC;
          chainMoves = nxt;
          legalMoves = nxt;
          if (turn == 2 && vsAI) triggerAiContinue = true;
          return;
        }
      } else {
        playMoveSound();
      }

      chainMode = false;
      chainMoves = [];
      selR = null;
      selC = null;
      legalMoves = [];

      int w = 0, b = 0;
      for (var row in board) {
        for (var v in row) {
          if (v == 1) w++;
          if (v == 2) b++;
        }
      }
      if (w == 1 && b == 1) {
        pendingDraw = true;
        return;
      }
      if (w == 0 || b == 0) {
        pendingWinner = b == 0 ? 1 : 2;
        return;
      }
      turn = turn == 1 ? 2 : 1;
      if (getAllMoves(turn).isEmpty) {
        pendingWinner = turn == 1 ? 2 : 1;
        return;
      }
      if (vsAI && turn == 2) triggerAiNext = true;
    });

    // Anything that shows a dialog or schedules further play happens
    // *after* setState, once the frame reflecting the move above is queued.
    if (pendingDraw) {
      _showDrawDialog();
      return;
    }
    if (pendingWinner != null) {
      win(pendingWinner!);
      return;
    }
    if (triggerAiContinue) {
      Future.delayed(const Duration(milliseconds: 260), () {
        if (mounted && chainMode) doMove(chainMoves.first, isChainCont: true);
      });
    }
    if (triggerAiNext) {
      Future.delayed(const Duration(milliseconds: 260), () {
        if (mounted) aiMove();
      });
    }
  }

  void _showDrawDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Draw!"),
        content: const Text("1 vs 1 - Draw by rule"),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              reset();
            },
            child: const Text("New Game"),
          )
        ],
      ),
    );
  }

  int evalBoard(List<List<int>> b) {
    int w = 0, bl = 0, wMob = 0, bMob = 0;
    for (int r = 0; r < 5; r++) {
      for (int c = 0; c < 5; c++) {
        if (b[r][c] == 1) {
          w++;
          wMob += capsFrom(r, c, b).length;
        }
        if (b[r][c] == 2) {
          bl++;
          bMob += capsFrom(r, c, b).length;
        }
      }
    }
    int center = b[2][2] == 2
        ? 4
        : b[2][2] == 1
            ? -4
            : 0;
    return (bl - w) * 100 + (bMob - wMob) * 18 + center;
  }

  int minimax(List<List<int>> b, int depth, bool maxing, int alpha, int beta,
      int curTurn) {
    int w = 0, bl = 0;
    for (var row in b) {
      for (var v in row) {
        if (v == 1) w++;
        if (v == 2) bl++;
      }
    }
    if (depth == 0 || w == 0 || bl == 0 || (w == 1 && bl == 1)) {
      return evalBoard(b);
    }
    var moves = allMoves(curTurn, b);
    if (moves.isEmpty) return maxing ? -9999 : 9999;
    if (maxing) {
      int best = -1000000;
      for (var m in moves) {
        var nb = clone(b);
        nb[m.toR][m.toC] = nb[m.fromR][m.fromC];
        nb[m.fromR][m.fromC] = 0;
        if (m.isCapture) nb[m.capR!][m.capC!] = 0;
        int sc =
            minimax(nb, depth - 1, false, alpha, beta, curTurn == 1 ? 2 : 1);
        best = sc > best ? sc : best;
        alpha = best > alpha ? best : alpha;
        if (beta <= alpha) break;
      }
      return best;
    } else {
      int best = 1000000;
      for (var m in moves) {
        var nb = clone(b);
        nb[m.toR][m.toC] = nb[m.fromR][m.fromC];
        nb[m.fromR][m.fromC] = 0;
        if (m.isCapture) nb[m.capR!][m.capC!] = 0;
        int sc =
            minimax(nb, depth - 1, true, alpha, beta, curTurn == 1 ? 2 : 1);
        best = sc < best ? sc : best;
        beta = best < beta ? best : beta;
        if (beta <= alpha) break;
      }
      return best;
    }
  }

  Move bestWithDepth(List<Move> moves, int depth) {
    int bestScore = -10000000;
    Move best = moves.first;
    for (var m in moves) {
      var nb = clone(board);
      nb[m.toR][m.toC] = nb[m.fromR][m.fromC];
      nb[m.fromR][m.fromC] = 0;
      if (m.isCapture) nb[m.capR!][m.capC!] = 0;
      int sc = minimax(nb, depth - 1, false, -10000000, 10000000, 1);
      if (sc > bestScore) {
        bestScore = sc;
        best = m;
      }
    }
    return best;
  }

  void aiMove() {
    var moves = getAllMoves(2);
    if (moves.isEmpty) return;
    Move chosen;
    switch (diff) {
      case AIDiff.easy:
        chosen = moves[rand.nextInt(moves.length)];
        break;
      case AIDiff.medium:
        var caps = moves.where((m) => m.isCapture).toList();
        chosen = caps.isNotEmpty && rand.nextDouble() > 0.3
            ? caps[rand.nextInt(caps.length)]
            : moves[rand.nextInt(moves.length)];
        break;
      case AIDiff.hard:
        chosen = bestWithDepth(moves, 2);
        break;
      case AIDiff.expert:
        chosen = bestWithDepth(moves, 3);
        break;
      case AIDiff.master:
        chosen = bestWithDepth(moves, 4);
        break;
    }
    doMove(chosen, isChainCont: false);
  }

  void win(int winner) {
    playWinSound();
    if (winner == 1) {
      whiteWins++;
    } else {
      blackWins++;
    }
    saveScore();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(winner == 1 ? "White Wins!" : "Black Wins!"),
        content: Text("Score W $whiteWins : $blackWins B"),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              reset();
            },
            child: const Text("New Game"),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3E2723),
      appBar: AppBar(
        backgroundColor: const Color(0xFF4E342E),
        foregroundColor: Colors.white,
        title: const Text("Natha Kalb - نطة كلب"),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: (chainMode || history.isEmpty) ? null : undo,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: reset),
        ],
      ),
      body: Column(children: [
        Container(
          color: const Color(0xFF5D4037),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(children: [
            Row(children: [
              Expanded(
                child: SwitchListTile(
                  value: mandatoryCapture,
                  activeColor: Colors.amber,
                  dense: true,
                  title: const Text("Mandatory",
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                  onChanged: (v) => setState(() => mandatoryCapture = v),
                ),
              ),
              Expanded(
                child: SwitchListTile(
                  value: vsAI,
                  activeColor: Colors.amber,
                  dense: true,
                  title: const Text("vs AI",
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                  onChanged: (v) => setState(() => vsAI = v),
                ),
              ),
            ]),
            Row(children: [
              const Text("AI:", style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 8),
              DropdownButton<AIDiff>(
                value: diff,
                dropdownColor: const Color(0xFF4E342E),
                style: const TextStyle(color: Colors.white),
                items: const [
                  DropdownMenuItem(value: AIDiff.easy, child: Text("Easy")),
                  DropdownMenuItem(
                      value: AIDiff.medium, child: Text("Medium")),
                  DropdownMenuItem(value: AIDiff.hard, child: Text("Hard")),
                  DropdownMenuItem(
                      value: AIDiff.expert, child: Text("Expert")),
                  DropdownMenuItem(
                      value: AIDiff.master, child: Text("Master")),
                ],
                onChanged: (v) => setState(() => diff = v!),
              ),
              const Spacer(),
              Text(
                "W $whiteWins:$blackWins B ${turn == 1 ? 'WHITE' : 'BLACK'}${chainMode ? ' CHAIN!' : ''}",
                style: const TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
              ),
            ]),
          ]),
        ),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                margin: const EdgeInsets.all(14),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(
                      colors: [Color(0xFF8D6E63), Color(0xFF5D4037)]),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black54,
                        blurRadius: 12,
                        offset: Offset(0, 6))
                  ],
                ),
                child: GridView.builder(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: 25,
                  itemBuilder: (_, i) {
                    int r = i ~/ 5, c = i % 5;
                    bool sel = selR == r && selC == c;
                    bool legal =
                        legalMoves.any((m) => m.toR == r && m.toC == c);
                    bool isCap = legalMoves
                        .any((m) => m.toR == r && m.toC == c && m.isCapture);
                    bool justMoved = _lastToR == r && _lastToC == c;

                    return GestureDetector(
                      onTap: () => onTap(r, c),
                      child: Container(
                        decoration: BoxDecoration(
                          color: sel
                              ? Colors.yellow[300]
                              : (r + c) % 2 == 0
                                  ? const Color(0xFFD7CCC8)
                                  : const Color(0xFF8D6E63),
                          borderRadius: BorderRadius.circular(6),
                          border: legal
                              ? Border.all(
                                  color: isCap
                                      ? Colors.redAccent
                                      : Colors.greenAccent,
                                  width: 3)
                              : null,
                        ),
                        child: Center(
                          child: TweenAnimationBuilder<double>(
                            key: justMoved
                                ? ValueKey('pop-$_moveSeq')
                                : ValueKey('cell-$r-$c'),
                            tween: Tween(
                                begin: justMoved ? 0.35 : 1.0, end: 1.0),
                            duration: const Duration(milliseconds: 140),
                            curve: Curves.easeOutBack,
                            builder: (context, scale, child) =>
                                Transform.scale(scale: scale, child: child),
                            child: _pawn(board[r][c]),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _pawn(int v) {
    if (v == 0) return const SizedBox();
    bool isW = v == 1;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isW
              ? [Colors.white, const Color(0xFFBDBDBD)]
              : [const Color(0xFF616161), Colors.black],
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 4,
              offset: const Offset(0, 2))
        ],
        border: Border.all(
            color: isW ? Colors.white70 : Colors.black87, width: 1.5),
      ),
      child: Container(
        margin: const EdgeInsets.only(top: 5, left: 5, right: 7, bottom: 10),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [Colors.white.withOpacity(0.75), Colors.transparent],
            center: const Alignment(-0.3, -0.5),
            radius: 0.7,
          ),
        ),
      ),
    );
  }
}
