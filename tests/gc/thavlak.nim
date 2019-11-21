discard """
  output: '''Welcome to LoopTesterApp, Nim edition
Constructing Simple CFG...
15000 dummy loops
Constructing CFG...
Performing Loop Recognition
1 Iteration
Another 5 iterations...
.....
Found 1 loops (including artificial root node) (5)'''
"""

# bug #3184

import tables, sets

when not declared(withScratchRegion):
  template withScratchRegion(body: untyped) = body

type
  BasicBlock = object
    inEdges: seq[ref BasicBlock]
    outEdges: seq[ref BasicBlock]
    name: int

proc newBasicBlock(name: int): ref BasicBlock =
  result = (ref BasicBlock)(
    inEdges: newSeq[ref BasicBlock](),
    outEdges: newSeq[ref BasicBlock](),
    name: name
  )

proc hash(x: ref BasicBlock): int {.inline.} =
  result = x.name

type
  BasicBlockEdge = object
    fr: ref BasicBlock
    to: ref BasicBlock

  Cfg = object
    basicBlockMap: Table[int, ref BasicBlock]
    edgeList: seq[BasicBlockEdge]
    startNode: ref BasicBlock

proc newCfg(): Cfg =
  result = Cfg(
    basicBlockMap: initTable[int, ref BasicBlock](),
    edgeList: newSeq[BasicBlockEdge](),
    startNode: nil)

proc createNode(self: var Cfg, name: int): ref BasicBlock =
  result = self.basicBlockMap.getOrDefault(name)
  if result == nil:
    result = newBasicBlock(name)
    self.basicBlockMap.add name, result

  if self.startNode == nil:
    self.startNode = result

proc newBasicBlockEdge(cfg: var Cfg, fromName, toName: int) =
  var result = BasicBlockEdge(
    fr: cfg.createNode(fromName),
    to: cfg.createNode(toName)
  )
  result.fr.outEdges.add(result.to)
  result.to.inEdges.add(result.fr)
  cfg.edgeList.add(result)

type
  SimpleLoop = object
    basicBlocks: seq[ref BasicBlock] # TODO: set here
    children: seq[ref SimpleLoop] # TODO: set here
    parent: ref SimpleLoop
    header: ref BasicBlock
    isRoot, isReducible: bool
    counter, nestingLevel, depthLevel: int

proc setParent(self: ref SimpleLoop, parent: ref SimpleLoop) =
  self.parent = parent
  self.parent.children.add self

proc setHeader(self: ref SimpleLoop, bb: ref BasicBlock) =
  self.basicBlocks.add(bb)
  self.header = bb

proc setNestingLevel(self: ref SimpleLoop, level: int) =
  self.nestingLevel = level
  if level == 0: self.isRoot = true

var loopCounter: int = 0

type
  Lsg = object
    loops: seq[ref SimpleLoop]
    root: ref SimpleLoop

proc createNewLoop(self: var Lsg): ref SimpleLoop =
  result = (ref SimpleLoop)(
    basicBlocks: newSeq[ref BasicBlock](),
    children: newSeq[ref SimpleLoop](),
    isReducible: true)
  loopCounter += 1
  result.counter = loopCounter

proc addLoop(self: var Lsg, l: ref SimpleLoop) =
  self.loops.add l

proc newLsg(): Lsg =
  result = Lsg(loops: newSeq[ref SimpleLoop](),
    root: result.createNewLoop())
  result.root.setNestingLevel(0)
  result.addLoop(result.root)

type
  UnionFindNode = object
    parent {.cursor.}: ref UnionFindNode
    bb: ref BasicBlock
    l: ref SimpleLoop
    dfsNumber: int

proc initNode(self: ref UnionFindNode, bb: ref BasicBlock, dfsNumber: int) =
  self.parent = self
  self.bb = bb
  self.dfsNumber = dfsNumber

proc findSet(self: ref UnionFindNode): ref UnionFindNode =
  var nodeList = newSeq[ref UnionFindNode]()
  var it {.cursor.} = self

  while it != it.parent:
    var parent {.cursor.} = it.parent
    if parent != parent.parent: nodeList.add it
    it = parent

  for iter in nodeList: iter.parent = it.parent
  result = it

proc union(self: ref UnionFindNode, unionFindNode: ref UnionFindNode) =
  self.parent = unionFindNode


const
  BB_NONHEADER = 1 # a regular BB
  BB_REDUCIBLE = 2 # reducible loop
  BB_SELF = 3 # single BB loop
  BB_IRREDUCIBLE = 4 # irreducible loop
  BB_DEAD = 5 # a dead BB

  # # Marker for uninitialized nodes.
  UNVISITED = -1

  # # Safeguard against pathologic algorithm behavior.
  MAXNONBACKPREDS = (32 * 1024)

type
  HavlakLoopFinder = object
    cfg: Cfg
    lsg: Lsg

proc newHavlakLoopFinder(cfg: Cfg, lsg: sink Lsg): HavlakLoopFinder =
  result = HavlakLoopFinder(cfg: cfg, lsg: lsg)

proc isAncestor(w: int, v: int, last: seq[int]): bool =
  w <= v and v <= last[w]

proc dfs(currentNode: ref BasicBlock, nodes: var seq[ref UnionFindNode],
         number: var Table[ref BasicBlock, int],
         last: var seq[int], current: int) =
  var stack = @[(currentNode, current)]
  while stack.len > 0:
    let (currentNode, current) = stack.pop()
    nodes[current].initNode(currentNode, current)
    number[currentNode] = current

    for target in currentNode.outEdges:
      if number[target] == UNVISITED:
        stack.add((target, current+1))
        #result = dfs(target, nodes, number, last, result + 1)
  last[number[currentNode]] = current

proc findLoops(self: var HavlakLoopFinder): int =
  var startNode = self.cfg.startNode
  if startNode == nil: return 0
  var size = self.cfg.basicBlockMap.len

  var nonBackPreds = newSeq[HashSet[int]]()
  var backPreds = newSeq[seq[int]]()
  var number = initTable[ref BasicBlock, int]()
  var header = newSeq[int](size)
  var types = newSeq[int](size)
  var last = newSeq[int](size)
  var nodes = newSeq[ref UnionFindNode]()

  for i in 1..size:
    nonBackPreds.add initHashSet[int](1)
    backPreds.add newSeq[int]()
    nodes.add((ref UnionFindNode)())

  # Step a:
  #   - initialize all nodes as unvisited.
  #   - depth-first traversal and numbering.
  #   - unreached BB's are marked as dead.
  #
  for v in self.cfg.basicBlockMap.values: number[v] = UNVISITED
  dfs(startNode, nodes, number, last, 0)

  # Step b:
  #   - iterate over all nodes.
  #
  #   A backedge comes from a descendant in the DFS tree, and non-backedges
  #   from non-descendants (following Tarjan).
  #
  #   - check incoming edges 'v' and add them to either
  #     - the list of backedges (backPreds) or
  #     - the list of non-backedges (nonBackPreds)
  #
  for w in 0 ..< size:
    header[w] = 0
    types[w]  = BB_NONHEADER

    var nodeW = nodes[w].bb
    if nodeW != nil:
      for nodeV in nodeW.inEdges:
        var v = number[nodeV]
        if v != UNVISITED:
          if isAncestor(w, v, last):
            backPreds[w].add v
          else:
            nonBackPreds[w].incl v
    else:
      types[w] = BB_DEAD

  # Start node is root of all other loops.
  header[0] = 0

  # Step c:
  #
  # The outer loop, unchanged from Tarjan. It does nothing except
  # for those nodes which are the destinations of backedges.
  # For a header node w, we chase backward from the sources of the
  # backedges adding nodes to the set P, representing the body of
  # the loop headed by w.
  #
  # By running through the nodes in reverse of the DFST preorder,
  # we ensure that inner loop headers will be processed before the
  # headers for surrounding loops.

  for w in countdown(size - 1, 0):
    # this is 'P' in Havlak's paper
    var nodePool = newSeq[ref UnionFindNode]()

    var nodeW = nodes[w].bb
    if nodeW != nil: # dead BB
      # Step d:
      for v in backPreds[w]:
        if v != w:
          nodePool.add nodes[v].findSet
        else:
          types[w] = BB_SELF

      # Copy nodePool to workList.
      #
      var workList = newSeq[ref UnionFindNode]()
      for x in nodePool: workList.add x

      if nodePool.len != 0: types[w] = BB_REDUCIBLE

      # work the list...
      #
      while workList.len > 0:
        var x = workList[0]
        workList.del(0)

        # Step e:
        #
        # Step e represents the main difference from Tarjan's method.
        # Chasing upwards from the sources of a node w's backedges. If
        # there is a node y' that is not a descendant of w, w is marked
        # the header of an irreducible loop, there is another entry
        # into this loop that avoids w.
        #

        # The algorithm has degenerated. Break and
        # return in this case.
        #
        var nonBackSize = nonBackPreds[x.dfsNumber].len
        if nonBackSize > MAXNONBACKPREDS: return 0

        for iter in nonBackPreds[x.dfsNumber]:
          var y = nodes[iter]
          var ydash = y.findSet

          if not isAncestor(w, ydash.dfsNumber, last):
            types[w] = BB_IRREDUCIBLE
            nonBackPreds[w].incl ydash.dfsNumber
          else:
            if ydash.dfsNumber != w and not nodePool.contains(ydash):
              workList.add ydash
              nodePool.add ydash

      # Collapse/Unionize nodes in a SCC to a single node
      # For every SCC found, create a loop descriptor and link it in.
      #
      if nodePool.len > 0 or types[w] == BB_SELF:
        var l = self.lsg.createNewLoop

        l.setHeader(nodeW)
        l.isReducible = types[w] != BB_IRREDUCIBLE

        # At this point, one can set attributes to the loop, such as:
        #
        # the bottom node:
        #    iter  = backPreds(w).begin();
        #    loop bottom is: nodes(iter).node;
        #
        # the number of backedges:
        #    backPreds(w).size()
        #
        # whether this loop is reducible:
        #    types(w) != BB_IRREDUCIBLE
        #
        nodes[w].l = l

        for node in nodePool:
          # Add nodes to loop descriptor.
          header[node.dfsNumber] = w
          node.union(nodes[w])

          # Nested loops are not added, but linked together.
          var nodeL = node.l
          if nodeL != nil:
            nodeL.setParent(l)
          else:
            l.basicBlocks.add node.bb

        self.lsg.addLoop(l)

  result = self.lsg.loops.len


type
  LoopTesterApp = object
    cfg: Cfg
    lsg: Lsg

proc newLoopTesterApp(): LoopTesterApp =
  result.cfg = newCfg()
  result.lsg = newLsg()

proc buildDiamond(self: var LoopTesterApp, start: int): int =
  newBasicBlockEdge(self.cfg, start, start + 1)
  newBasicBlockEdge(self.cfg, start, start + 2)
  newBasicBlockEdge(self.cfg, start + 1, start + 3)
  newBasicBlockEdge(self.cfg, start + 2, start + 3)
  result = start + 3

proc buildConnect(self: var LoopTesterApp, start1: int, end1: int) =
  newBasicBlockEdge(self.cfg, start1, end1)

proc buildStraight(self: var LoopTesterApp, start: int, n: int): int =
  for i in 0..n-1:
    self.buildConnect(start + i, start + i + 1)
  result = start + n

proc buildBaseLoop(self: var LoopTesterApp, from1: int): int =
  let header = self.buildStraight(from1, 1)
  let diamond1 = self.buildDiamond(header)
  let d11 = self.buildStraight(diamond1, 1)
  let diamond2 = self.buildDiamond(d11)
  let footer = self.buildStraight(diamond2, 1)

  self.buildConnect(diamond2, d11)
  self.buildConnect(diamond1, header)
  self.buildConnect(footer, from1)
  result = self.buildStraight(footer, 1)

proc run(self: var LoopTesterApp) =
  echo "Welcome to LoopTesterApp, Nim edition"
  echo "Constructing Simple CFG..."

  discard self.cfg.createNode(0)
  discard self.buildBaseLoop(0)
  discard self.cfg.createNode(1)
  self.buildConnect(0, 2)

  echo "15000 dummy loops"

  for i in 1..15000:
    withScratchRegion:
      var h = newHavlakLoopFinder(self.cfg, newLsg())
      discard h.findLoops

  echo "Constructing CFG..."
  var n = 2

  for parlooptrees in 1..10:
    discard self.cfg.createNode(n + 1)
    self.buildConnect(2, n + 1)
    n += 1
    for i in 1..100:
      var top = n
      n = self.buildStraight(n, 1)
      for j in 1..25: n = self.buildBaseLoop(n)
      var bottom = self.buildStraight(n, 1)
      self.buildConnect n, top
      n = bottom
    self.buildConnect(n, 1)

  echo "Performing Loop Recognition\n1 Iteration"

  var h = newHavlakLoopFinder(self.cfg, newLsg())
  var loops = h.findLoops

  echo "Another 5 iterations..."

  var sum = 0
  for i in 1..5:
    withScratchRegion:
      write stdout, "."
      flushFile(stdout)
      var hlf = newHavlakLoopFinder(self.cfg, newLsg())
      sum += hlf.findLoops
      #echo getOccupiedMem()
  echo "\nFound ", loops, " loops (including artificial root node) (", sum, ")"

  when false:
    echo("Total memory available: " & formatSize(getTotalMem()) & " bytes")
    echo("Free memory: " & formatSize(getFreeMem()) & " bytes")

var l = newLoopTesterApp()
l.run
