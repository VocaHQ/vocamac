// 404 page only: the 1984 Mac Puzzle desk accessory, a 4x4 sliding puzzle.
(() => {
  "use strict";

  const board = document.querySelector("[data-puzzle-board]");
  if (!board) return;

  const bar = document.querySelector("[data-puzzle-bar]");
  const movesOut = document.querySelector("[data-puzzle-moves]");
  const shuffleButton = document.querySelector("[data-puzzle-shuffle]");
  const note = document.querySelector("[data-puzzle-note]");
  const live = document.querySelector("[data-puzzle-live]");

  const SIZE = 4;
  const SOLVED = Array.from({ length: SIZE * SIZE }, (_, i) => (i + 1) % (SIZE * SIZE));
  const tiles = [];
  let cells = SOLVED.slice(); // cells[i] is the tile number at cell i; 0 is the gap.
  let moves = 0;
  let solved = true;

  const row = (i) => Math.floor(i / SIZE);
  const col = (i) => i % SIZE;
  const isSolved = () => cells.every((n, i) => n === SOLVED[i]);
  const plural = (n) => `${n} move${n === 1 ? "" : "s"}`;

  function neighbours(i) {
    const out = [];
    if (row(i) > 0) out.push(i - SIZE);
    if (row(i) < SIZE - 1) out.push(i + SIZE);
    if (col(i) > 0) out.push(i - 1);
    if (col(i) < SIZE - 1) out.push(i + 1);
    return out;
  }

  // Swap the tile at `from` into the gap. Only legal when they touch.
  function slide(from) {
    const gap = cells.indexOf(0);
    if (!neighbours(gap).includes(from)) return false;
    cells[gap] = cells[from];
    cells[from] = 0;
    return true;
  }

  function render() {
    const near = neighbours(cells.indexOf(0));
    cells.forEach((n, i) => {
      if (!n) return;
      const tile = tiles[n];
      const movable = !solved && near.includes(i);
      tile.style.setProperty("--x", col(i));
      tile.style.setProperty("--y", row(i));
      tile.classList.toggle("is-movable", movable);
      tile.setAttribute(
        "aria-label",
        `${n}, row ${row(i) + 1}, column ${col(i) + 1}${movable ? ", next to the gap" : ""}`,
      );
    });
    movesOut.textContent = String(moves);
    board.classList.toggle("is-solved", solved);
  }

  function announce(message) {
    live.textContent = message;
  }

  // Start from the solved board and make random legal moves, so every
  // shuffle is reachable from (and therefore back to) the solution.
  function shuffle(quiet) {
    cells = SOLVED.slice();
    let previousGap = -1;
    for (let step = 0; step < 200 || isSolved(); step += 1) {
      const gap = cells.indexOf(0);
      const options = neighbours(gap).filter((i) => i !== previousGap);
      slide(options[Math.floor(Math.random() * options.length)]);
      previousGap = gap;
    }
    moves = 0;
    solved = false;
    note.textContent = "Click a tile next to the gap, or focus the board and use the arrow keys.";
    render();
    if (!quiet) announce("Shuffled. Put the tiles back in order, 1 to 15.");
  }

  function move(from) {
    if (solved || from < 0) return;
    const gap = cells.indexOf(0);
    const n = cells[from];
    if (!slide(from)) {
      announce(`${n} is not next to the gap.`);
      return;
    }
    moves += 1;
    const direction = { 1: "right", [-1]: "left", [SIZE]: "down", [-SIZE]: "up" }[gap - from];
    if (isSolved()) {
      solved = true;
      note.textContent = `Solved in ${plural(moves)}. Happy Mac! Press Shuffle to play again.`;
      announce(note.textContent);
    } else {
      announce(`${n} moved ${direction}. ${plural(moves)}.`);
    }
    render();
  }

  board.textContent = "";
  for (let n = 1; n < SIZE * SIZE; n += 1) {
    const tile = document.createElement("button");
    tile.type = "button";
    tile.className = "tile";
    tile.tabIndex = -1;
    tile.textContent = String(n);
    tile.dataset.n = String(n);
    tiles[n] = tile;
    board.append(tile);
  }

  board.removeAttribute("aria-hidden");
  board.setAttribute("role", "group");
  board.setAttribute("aria-labelledby", "puzzle-title");
  board.setAttribute("aria-describedby", "puzzle-note");
  board.tabIndex = 0;
  board.classList.add("is-live");
  bar.hidden = false;

  board.addEventListener("click", (event) => {
    const tile = event.target.closest("button.tile");
    if (tile) move(cells.indexOf(Number(tile.dataset.n)));
  });

  // An arrow pushes the tile on the far side of the gap in that direction.
  board.addEventListener("keydown", (event) => {
    const gap = cells.indexOf(0);
    const from = {
      ArrowUp: row(gap) < SIZE - 1 ? gap + SIZE : -1,
      ArrowDown: row(gap) > 0 ? gap - SIZE : -1,
      ArrowLeft: col(gap) < SIZE - 1 ? gap + 1 : -1,
      ArrowRight: col(gap) > 0 ? gap - 1 : -1,
    }[event.key];
    if (from === undefined) return;
    event.preventDefault();
    move(from);
  });

  shuffleButton.addEventListener("click", () => shuffle(false));

  shuffle(true);
})();
