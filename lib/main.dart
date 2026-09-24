import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const OrthogonalPawnsApp());
}

class OrthogonalPawnsApp extends StatelessWidget {
  const OrthogonalPawnsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orthogonal Pawns',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF8D6E63),
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1B1210),
      ),
      home: const GameScreen(),
    );
  }
}

// =====================================================================
// GAME MODEL
// =====================================================================

const int kEmpty = 0;
const int kWhite = 1;
const int kBlack = 2;

/// Orthogonal directions: Up, Down, Left, Right.
const List<List<int>> kDirs = [
  [-1, 0],
  [1, 0],
  [0, -1],
  [0, 1],
];

int opponentOf(int player) => player == kWhite ? kBlack : kWhite;

bool inBounds(int r, int c) => r >= 0 && r < 5 && c >= 0 && c < 5;

class Move {
  final int fromR, fromC, toR, toC;
  final int? capR, capC;
  const Move(this.fromR, this.fromC, this.toR, this.toC, {this.capR, this.capC});
  bool get isCapture => capR != null;

  @override
  bool operator ==(Object other) =>
      other is Move &&
      other.fromR == fromR &&
      other.fromC == fromC &&
      other.toR == toR &&
      other.toC == toC;

  @override
  int get hashCode => Object.hash(fromR, fromC, toR, toC);
}

class GameSnapshot {
  final List<List<int>> board;
  final int turn;
  final int whiteCaps;
  final int blackCaps;
  const GameSnapshot(this.board, this.turn, this.whiteCaps, this.blackCaps);
}

List<List<int>> cloneBoard(List<List<int>> b) =>
    b.map((row) => List<int>.from(row)).toList(growable: false);

/// Initial position per spec.
/// board[0] = bottom row (White back rank), board[4] = top row (Black back rank).
List<List<int>> initialBoard() {
  return [
    [kWhite, kWhite, kWhite, kWhite, kWhite], // row0 - White back rank
    [kWhite, kWhite, kWhite, kWhite, kWhite], // row1 - White
    [kWhite, kWhite, kEmpty, kBlack, kBlack], // row2 - mixed, center empty
    [kBlack, kBlack, kBlack, kBlack, kBlack], // row3 - Black
    [kBlack, kBlack, kBlack, kBlack, kBlack], // row4 - Black back rank
  ];
}

List<Move> getCapturesFrom(int r, int c, List<List<int>> board) {
  final int player = board[r][c];
  if (player == kEmpty) return [];
  final int enemy = opponentOf(player);
  final List<Move> caps = [];
  for (final d in kDirs) {
    final er = r + d[0], ec = c + d[1];
    final lr = r + d[0] * 2, lc = c + d[1] * 2;
    if (inBounds(er, ec) &&
        inBounds(lr, lc) &&
        board[er][ec] == enemy &&
        board[lr][lc] == kEmpty) {
      caps.add(Move(r, c, lr, lc, capR: er, capC: ec));
    }
  }
  return caps;
}

List<Move> getMovesFrom(int r, int c, List<List<int>> board) {
  final List<Move> moves = [];
  for (final d in kDirs) {
    final nr = r + d[0], nc = c + d[1];
    if (inBounds(nr, nc) && board[nr][nc] == kEmpty) {
      moves.add(Move(r, c, nr, nc));
    }
  }
  return moves;
}

/// All legal moves for [player]. If [mandatoryCapture] is true and any
/// capture exists anywhere on the board for this player, only captures
/// are returned (normal moves are illegal for every pawn).
List<Move> getAllMoves(int player, List<List<int>> board, bool mandatoryCapture) {
  final List<Move> caps = [];
  final List<Move> moves = [];
  for (int r = 0; r < 5; r++) {
    for (int c = 0; c < 5; c++) {
      if (board[r][c] == player) {
        caps.addAll(getCapturesFrom(r, c, board));
        moves.addAll(getMovesFrom(r, c, board));
      }
    }
  }
  if (mandatoryCapture && caps.isNotEmpty) return caps;
  return [...caps, ...moves];
}

int countPawns(List<List<int>> board, int player) {
  int n = 0;
  for (final row in board) {
    for (final v in row) {
      if (v == player) n++;
    }
  }
  return n;
}

/// Applies [move] to [board] in place, removing a captured pawn if any.
void applyMove(List<List<int>> board, Move move) {
  final piece = board[move.fromR][move.fromC];
  board[move.fromR][move.fromC] = kEmpty;
  board[move.toR][move.toC] = piece;
  if (move.isCapture) {
    board[move.capR!][move.capC!] = kEmpty;
  }
}

/// Estimates the longest capture chain achievable starting with [move]
/// (used by the simple AI to prefer bigger chains). Depth-limited by the
/// natural shrinking board; safe against infinite loops since each
/// capture removes a pawn.
int chainPotential(Move move, List<List<int>> board) {
  final b = cloneBoard(board);
  applyMove(b, move);
  final next = getCapturesFrom(move.toR, move.toC, b);
  if (next.isEmpty) return 1;
  int best = 0;
  for (final m in next) {
    final p = chainPotential(m, b);
    if (p > best) best = p;
  }
  return 1 + best;
}

// =====================================================================
// GAME SCREEN
// =====================================================================

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  late List<List<int>> board;
  int turn = kWhite;
  bool mandatoryCapture = true;
  bool vsAI = true;
  int whiteCaps = 0;
  int blackCaps = 0;
  int whiteWins = 0;
  int blackWins = 0;
  int movesSinceCapture = 0;

  final List<GameSnapshot> history = [];

  int? selR, selC;
  List<Move> legalMovesForSelection = [];

  bool chainMode = false;
  int? chainR, chainC;

  bool aiThinking = false;
  bool gameOver = false;
  String? winnerMessage;

  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    board = initialBoard();
    _loadScores();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadScores() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        whiteWins = prefs.getInt('whiteWins') ?? 0;
        blackWins = prefs.getInt('blackWins') ?? 0;
      });
    } catch (_) {
      // Ignore storage errors; scores just won't persist this session.
    }
  }

  Future<void> _saveScores() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('whiteWins', whiteWins);
      await prefs.setInt('blackWins', blackWins);
    } catch (_) {
      // Ignore storage errors.
    }
  }

  Future<void> _playSound(String name) async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/$name'));
    } catch (_) {
      // Asset missing or platform audio unavailable - fail silently per spec.
    }
  }

  // -------------------- Core turn logic --------------------

  void _pushHistory() {
    history.add(GameSnapshot(cloneBoard(board), turn, whiteCaps, blackCaps));
  }

  void _selectSquare(int r, int c) {
    if (gameOver || aiThinking) return;
    if (chainMode) {
      // During a chain, only the chaining pawn's captures are selectable -
      // never normal moves, even if Mandatory Capture is toggled off.
      if (r != chainR || c != chainC) return;
      setState(() {
        selR = r;
        selC = c;
        legalMovesForSelection = getCapturesFrom(r, c, board);
      });
      return;
    }
    if (board[r][c] == turn) {
      _showMovesFor(r, c);
      return;
    }
    // Tapped a destination square while a pawn is already selected.
    if (selR != null && selC != null) {
      final match = legalMovesForSelection.where((m) => m.toR == r && m.toC == c);
      if (match.isNotEmpty) {
        _executeMove(match.first);
      }
    }
  }

  void _showMovesFor(int r, int c) {
    final all = getAllMoves(turn, board, mandatoryCapture);
    final fromHere = all.where((m) => m.fromR == r && m.fromC == c).toList();
    setState(() {
      selR = r;
      selC = c;
      legalMovesForSelection = fromHere;
    });
  }

  void _executeMove(Move move) {
    final bool wasChain = chainMode;
    if (!wasChain) {
      _pushHistory();
    }

    setState(() {
      applyMove(board, move);
      if (move.isCapture) {
        _playSound('capture.wav');
        if (turn == kWhite) {
          whiteCaps++;
        } else {
          blackCaps++;
        }
        movesSinceCapture = 0;
      } else {
        _playSound('move.wav');
        movesSinceCapture++;
      }

      selR = null;
      selC = null;
      legalMovesForSelection = [];

      // Chain capture: same pawn must continue if more captures exist.
      if (move.isCapture) {
        final further = getCapturesFrom(move.toR, move.toC, board);
        if (further.isNotEmpty) {
          chainMode = true;
          chainR = move.toR;
          chainC = move.toC;
          selR = move.toR;
          selC = move.toC;
          legalMovesForSelection = further;
          return;
        }
      }

      // Chain (if any) has ended, or this was a normal move.
      chainMode = false;
      chainR = null;
      chainC = null;
      // _endTurnAndCheckWin switches `turn` and, if it becomes Black's turn
      // with vsAI on, schedules the AI move itself - do not schedule again here.
      _endTurnAndCheckWin();
    });
  }

  void _endTurnAndCheckWin() {
    final opponent = opponentOf(turn);

    if (countPawns(board, opponent) == 0) {
      _declareWin(turn);
      return;
    }

    final opponentMoves = getAllMoves(opponent, board, mandatoryCapture);
    if (opponentMoves.isEmpty) {
      _declareWin(turn);
      return;
    }

    if (movesSinceCapture >= 30) {
      gameOver = true;
      winnerMessage = 'Draw - 30 moves without a capture';
      return;
    }

    turn = opponent;

    if (vsAI && turn == kBlack) {
      _scheduleAiMove();
    }
  }

  void _declareWin(int winner) {
    gameOver = true;
    if (winner == kWhite) {
      whiteWins++;
      winnerMessage = 'White wins!';
    } else {
      blackWins++;
      winnerMessage = 'Black wins!';
    }
    _playSound('win.wav');
    _saveScores();
  }

  // -------------------- AI --------------------

  void _scheduleAiMove() {
    aiThinking = true;
    Timer(const Duration(milliseconds: 350), _aiTakeTurn);
  }

  void _aiTakeTurn() {
    if (!mounted || gameOver) {
      aiThinking = false;
      return;
    }
    final moves = getAllMoves(kBlack, board, mandatoryCapture);
    if (moves.isEmpty) {
      aiThinking = false;
      return; // _endTurnAndCheckWin already handles this case before we get here.
    }

    final captures = moves.where((m) => m.isCapture).toList();
    Move chosen;
    if (captures.isNotEmpty) {
      captures.sort((a, b) => chainPotential(b, board).compareTo(chainPotential(a, board)));
      chosen = captures.first;
    } else {
      chosen = moves.first;
    }

    if (!wasChainingBlackMove) {
      _pushHistory();
    }

    setState(() {
      applyMove(board, chosen);
      if (chosen.isCapture) {
        _playSound('capture.wav');
        blackCaps++;
        movesSinceCapture = 0;
      } else {
        _playSound('move.wav');
        movesSinceCapture++;
      }
    });

    if (chosen.isCapture) {
      final further = getCapturesFrom(chosen.toR, chosen.toC, board);
      if (further.isNotEmpty) {
        wasChainingBlackMove = true;
        Timer(const Duration(milliseconds: 350), _aiTakeTurn);
        return;
      }
    }
    wasChainingBlackMove = false;
    aiThinking = false;
    setState(() {
      _endTurnAndCheckWin();
    });
  }

  bool wasChainingBlackMove = false;

  // -------------------- Undo / Reset --------------------

  void _undo() {
    if (chainMode || aiThinking || history.isEmpty) return;
    final snap = history.removeLast();
    setState(() {
      board = snap.board;
      turn = snap.turn;
      whiteCaps = snap.whiteCaps;
      blackCaps = snap.blackCaps;
      selR = null;
      selC = null;
      legalMovesForSelection = [];
      chainMode = false;
      chainR = null;
      chainC = null;
      gameOver = false;
      winnerMessage = null;
    });
  }

  void _reset() {
    setState(() {
      board = initialBoard();
      turn = kWhite;
      whiteCaps = 0;
      blackCaps = 0;
      movesSinceCapture = 0;
      history.clear();
      selR = null;
      selC = null;
      legalMovesForSelection = [];
      chainMode = false;
      chainR = null;
      chainC = null;
      gameOver = false;
      winnerMessage = null;
      aiThinking = false;
      wasChainingBlackMove = false;
    });
  }

  // -------------------- Build --------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orthogonal Pawns 5x5'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: Column(
                children: [
                  _buildTopBar(),
                  const SizedBox(height: 12),
                  _buildBoard(constraints),
                  const SizedBox(height: 12),
                  _buildScorePanel(),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          _switchTile('Mandatory Capture', mandatoryCapture, (v) {
            setState(() => mandatoryCapture = v);
          }),
          _switchTile('vs AI', vsAI, (v) {
            setState(() => vsAI = v);
          }),
          IconButton.filledTonal(
            onPressed: (chainMode || aiThinking || history.isEmpty) ? null : _undo,
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
          ),
          IconButton.filledTonal(
            onPressed: _reset,
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
          ),
        ],
      ),
    );
  }

  Widget _switchTile(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _buildBoard(BoxConstraints constraints) {
    final double side = math.min(constraints.maxWidth - 24, 420);
    return Container(
      width: side + 20,
      height: side + 20,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8D6E63), Color(0xFF3E2723)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          if (!gameOver)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                aiThinking
                    ? "Black (AI) is thinking..."
                    : "${turn == kWhite ? 'White' : 'Black'}'s turn${chainMode ? ' - continue chain!' : ''}",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                winnerMessage ?? '',
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5),
                itemCount: 25,
                itemBuilder: (context, index) {
                  final displayRow = index ~/ 5; // 0 = visual top
                  final col = index % 5;
                  final r = 4 - displayRow; // convert to board row (row4 = top)
                  final c = col;
                  return _buildSquare(r, c);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSquare(int r, int c) {
    final bool isDark = (r + c) % 2 == 0;
    final Color squareColor = isDark ? const Color(0xFF8D6E63) : const Color(0xFFD7CCC8);
    final bool isSelected = selR == r && selC == c;
    final Move? legalHere = legalMovesForSelection
        .cast<Move?>()
        .firstWhere((m) => m!.toR == r && m.toC == c, orElse: () => null);
    final int piece = board[r][c];

    Color? borderColor;
    double borderWidth = 0;
    if (isSelected) {
      borderColor = Colors.yellowAccent;
      borderWidth = 3;
    } else if (legalHere != null) {
      borderColor = legalHere.isCapture ? Colors.redAccent : Colors.greenAccent;
      borderWidth = 3;
    }

    return GestureDetector(
      onTap: () => _selectSquare(r, c),
      child: Container(
        margin: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          color: squareColor,
          border: borderColor != null ? Border.all(color: borderColor, width: borderWidth) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Center(
          child: piece == kEmpty
              ? (legalHere != null
                  ? Icon(
                      legalHere.isCapture ? Icons.close : Icons.circle,
                      size: legalHere.isCapture ? 22 : 14,
                      color: legalHere.isCapture ? Colors.redAccent : Colors.greenAccent,
                    )
                  : null)
              : _buildPawn(piece),
        ),
      ),
    );
  }

  Widget _buildPawn(int piece) {
    final bool isWhite = piece == kWhite;
    return FractionallySizedBox(
      widthFactor: 0.78,
      heightFactor: 0.78,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isWhite
                ? [Colors.white, Colors.grey.shade400]
                : [Colors.grey.shade800, Colors.black],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 3,
              offset: const Offset(1, 2),
            ),
          ],
          border: Border.all(color: Colors.black.withOpacity(0.3), width: 1),
        ),
        child: Center(
          child: Text(
            isWhite ? 'W' : 'B',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isWhite ? Colors.black87 : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScorePanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _scoreColumn('Wins - White', whiteWins),
                  _scoreColumn('Wins - Black', blackWins),
                ],
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _scoreColumn('Captures - White', whiteCaps),
                  _scoreColumn('Captures - Black', blackCaps),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scoreColumn(String label, int value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text('$value', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
