/*
  heySona visual explainer renderer.

  Turns a scene description into an animated, step-by-step explanation.
  Claude writes the scene description; nothing in it is executed as code.

  ─── Scene format ────────────────────────────────────────────────────────
  {
    "title": "How a rocket engine works",
    "mode": "3d",                         // "3d" (perspective, orbit) or "2d" (flat diagram)
    "camera": { "fit": true, "angle": [45, 20], "autoRotate": true },   or position/target
    "view": { "width": 16 },              // 2d only: how many units fit across
    "floor": true,                        // 3d only: subtle grid under the scene
    "objects": [ <object>, ... ],
    "steps": [ { "narration": "...", "seconds": 6, "actions": [ <action>, ... ] }, ... ]
  }

  Object (all numbers in scene units, angles in degrees):
    { "id": "tank", "shape": "cylinder", "radius": 1, "height": 3,
      "position": [x, y, z], "rotation": [x, y, z], "color": "#d9822b",
      "opacity": 1, "hidden": false, "metalness": 0.3, "roughness": 0.45 }
    shapes: box (size [w,h,d]), sphere (radius), cylinder (radius or
    radiusTop/radiusBottom, height), cone (radius, height), torus (radius,
    tube), lathe (profile [[radius, y], ...], a shape spun around the y axis,
    good for nozzles and bottles), tube (points [[x,y,z], ...], radius, for
    pipes), rect (size [w,h]), circle (radius), ring (innerRadius, outerRadius),
    line (points [[x,y,z], ...], width; straight segments, for graphs, axes,
    timelines; "drawn": false starts it invisible so "draw" can trace it),
    card (title, text, width in pixels; an HTML text box anchored at position;
    "code": true shows the text as code in a monospace font; "math": "LaTeX"
    typesets an equation with KaTeX, above the text),
    gear (radius, teeth, thickness, innerRadius, holeRadius; faces +z),
    capsule (radius, height; rounded ends), spring (radius, height, coils, wireRadius).
  Any action can have "delay": seconds, so one step plays in sequence
  (swap, then swap, then highlight) instead of all at once.

  Live sliders: { "do": "slider", "id": "lr", "label": "Learning rate", "min": 0.01,
  "max": 1, "step": 0.01, "value": 0.1 } shows a slider; its id is a variable.
  Objects react through expressions (numbers, + - * / ^, parentheses, pi, e,
  sin cos tan sqrt abs exp ln log log2 log10 min max floor ceil round pow):
    "bind": { "position": [x, y, z], "scale": s | [x, y, z], "opacity": o }
                         each value a number or an expression string like "lr * 4"
    line "plot": { "y": "a * x^2", "from": -3, "to": 3, "samples": 60,
                   "origin": [x, y], "unit": [sx, sy], "markers": 0.12 }
                   or { "iterate": { "start": 2.5, "next": "x - lr * 2 * x", "count": 12 }, "y": "x^2", ... }
                   (points of x, then next(x), ...: gradient descent steps)
    "[[expression]]" inside card title/text/math and label text shows a live value.
  Optional top-level "variables": { "a": 1 } sets starting values.
  Optional top-level "quiz": [{ "question", "choices": [...], "answerIndex", "explanation" }]
  is offered after the last step (and by the Quiz button).

  Actions (a "targets" field takes one id or a list of ids):
    show / hide          { "do": "show", "targets": ["tank"] }
    focus / unfocus      spotlight targets and dim everything else
    highlight            { "do": "highlight", "targets": "chamber", "color": "#ff7a1a", "glow": true }
    unhighlight
    cutaway              { "do": "cutaway", "targets": "shell", "opacity": 0.15 }   see-through shell
    color                { "do": "color", "targets": "x", "color": "#hex" }
    label                { "do": "label", "target": "tank", "text": "Fuel", "offset": [0, 1, 0] }
                         or { "do": "label", "position": [x,y,z], "text": "..." }
    unlabel              { "do": "unlabel", "targets": ["tank"] }
    arrow                { "do": "arrow", "from": [x,y,z] | "id", "to": [x,y,z] | "id", "text": "Thrust", "color": "#hex" }
    flow                 { "do": "flow", "path": ["tank", [0,2,0], "chamber"], "color": "#hex", "speed": 1.5, "count": 40 }
    plume                { "do": "plume", "from": "nozzle" | [x,y,z], "direction": [0,-1,0], "length": 5,
                           "spread": 0.35, "color": "#ffb347" }
    spin / stopSpin      { "do": "spin", "targets": "pump", "axis": "y", "speed": 1.5 }  (turns per second)
    camera               { "do": "camera", "position": [x,y,z], "target": [x,y,z], "seconds": 1.6 }
                         or { "do": "camera", "fit": ["nozzle", "chamber"], "angle": [45, 20] }
                         (fit frames those objects, or everything with "fit": true; angle is
                         [degrees around, degrees above the horizon] and is optional)
    orbit                { "do": "orbit", "enabled": false }
    clearEffects         removes arrows, flows, and plumes added by earlier steps
    draw                 { "do": "draw", "targets": "curve", "seconds": 2 }   trace a line (or tube) on screen
    move                 { "do": "move", "targets": "item3", "to": [x,y,z] | "by": [dx,dy,dz], "seconds": 1.2 }
    revolve / stopRevolve { "do": "revolve", "targets": "earth", "center": [0,0,0], "speed": 0.2, "axis": "y" }
                         orbit around a point (turns per second; axis defaults to z in 2d)
    add                  { "do": "add", "objects": [<object>, ...] }   bring in new objects during a step
    update               { "do": "update", "target": "eq", "math": "...", "text": "...", "title": "..." }
                         change a card's content (equation transforms, running totals)
    slider / hideSliders see "Live sliders" above

  ─── JavaScript API (called from Swift) ──────────────────────────────────
    heySonaExplainer.loadScene(scene, { autoAdvance: true, stepsStillStreaming: false })
    heySonaExplainer.appendSteps([step, ...])      add steps while they stream in
    heySonaExplainer.finishSteps()                 no more steps will come
    heySonaExplainer.goToStep(index)
    heySonaExplainer.play() / .pause()
    heySonaExplainer.setQuiz([...]) / .showQuiz() / .showLibrary([{ id, title, detail }])
    heySonaExplainer.continueScene()               follow-up steps are about to be appended
    heySonaExplainer.showConceptMap({ nodes: [{ id, label, kind, explanationId }], links: [{ from, to }] })
    heySonaExplainer.markFinished()                narration finished (offers the quiz)
  Messages to Swift (window.webkit.messageHandlers.heySona):
    { type: "ready" } | { type: "stepStarted", index, narration } | { type: "finished" }
    { type: "close" } | { type: "playPauseRequested", isPlaying } | { type: "error", message }
    { type: "libraryRequested" } | { type: "libraryEntrySelected", id } | { type: "libraryEntryDeleted", id }
    { type: "conceptMapRequested" }
    { type: "quizFinished", correctCount, questionCount }
*/

(function () {
  'use strict';

  const THREE = window.THREE;

  // ─── Native bridge ──────────────────────────────────────────────────────

  function postToNative(message) {
    try {
      window.webkit.messageHandlers.heySona.postMessage(message);
    } catch (bridgeError) {
      // Not running inside heySona (e.g. opened in a browser for testing).
    }
  }

  window.addEventListener('error', (errorEvent) => {
    postToNative({ type: 'error', message: String(errorEvent.message) });
  });

  // ─── DOM ────────────────────────────────────────────────────────────────

  const stageElement = document.getElementById('stage');
  const labelLayerElement = document.getElementById('label-layer');
  const loadingMessageElement = document.getElementById('loading-message');
  const sceneTitleElement = document.getElementById('scene-title');
  const stepCounterElement = document.getElementById('step-counter');
  const captionElement = document.getElementById('caption');
  const stepDotsElement = document.getElementById('step-dots');
  const playPauseButton = document.getElementById('play-pause-button');
  const previousButton = document.getElementById('previous-button');
  const nextButton = document.getElementById('next-button');
  const restartButton = document.getElementById('restart-button');
  const closeButton = document.getElementById('close-button');

  // ─── Three.js setup ─────────────────────────────────────────────────────

  // preserveDrawingBuffer keeps the last frame readable, so window
  // snapshots (and the test harness) capture the 3D content.
  const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(window.devicePixelRatio || 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  stageElement.insertBefore(renderer.domElement, labelLayerElement);

  const threeScene = new THREE.Scene();
  const perspectiveCamera = new THREE.PerspectiveCamera(42, 1, 0.05, 500);
  const orthographicCamera = new THREE.OrthographicCamera(-8, 8, 5, -5, -100, 100);
  let activeCamera = perspectiveCamera;

  threeScene.add(new THREE.HemisphereLight(0xdfe8ff, 0x1a1f2e, 1.1));
  const keyLight = new THREE.DirectionalLight(0xffffff, 1.6);
  keyLight.position.set(6, 10, 8);
  threeScene.add(keyLight);
  const rimLight = new THREE.DirectionalLight(0x6fa0ff, 0.9);
  rimLight.position.set(-8, 4, -6);
  threeScene.add(rimLight);

  /** Soft round dot used for every particle effect. */
  const particleTexture = (() => {
    const textureCanvas = document.createElement('canvas');
    textureCanvas.width = textureCanvas.height = 64;
    const textureContext = textureCanvas.getContext('2d');
    const gradient = textureContext.createRadialGradient(32, 32, 0, 32, 32, 32);
    gradient.addColorStop(0, 'rgba(255,255,255,1)');
    gradient.addColorStop(0.35, 'rgba(255,255,255,0.75)');
    gradient.addColorStop(1, 'rgba(255,255,255,0)');
    textureContext.fillStyle = gradient;
    textureContext.fillRect(0, 0, 64, 64);
    return new THREE.CanvasTexture(textureCanvas);
  })();

  // ─── State ──────────────────────────────────────────────────────────────

  const accentColor = new THREE.Color('#3380ff');

  const explainerState = {
    sceneDescription: null,
    steps: [],
    stepsStillStreaming: false,
    currentStepIndex: -1,
    isPlaying: true,
    autoAdvance: true,
    stepAdvanceTimer: null,
    isTwoDimensional: false,
    /** id → object record (see buildSceneObject). */
    objectRecordsById: new Map(),
    sceneObjectsGroup: new THREE.Group(),
    floorGrid: null,
    focusedObjectIds: null,
    /** Running arrows, flows, and plumes: { object3D, update(dt), dispose() }. */
    activeEffects: [],
    /** id or position-key → label record. */
    labelRecordsByKey: new Map(),
    cameraTween: null,
    /** Actions waiting for their "delay": { action, remainingSeconds }. */
    pendingDelayedActions: [],
    /** Slider and scene variables by name (no prototype, so only real names resolve). */
    variables: Object.create(null),
  };
  threeScene.add(explainerState.sceneObjectsGroup);

  /** Where the camera orbits from. Position = target + spherical(azimuth, polar, distance). */
  const cameraRig = {
    target: new THREE.Vector3(0, 0, 0),
    azimuthInRadians: 0.8,
    polarInRadians: 1.1,
    distance: 14,
    autoRotate: true,
    isUserDragging: false,
    orthographicZoom: 1,
  };

  // ─── Helpers ────────────────────────────────────────────────────────────

  function asArray(value) {
    if (value === undefined || value === null) return [];
    return Array.isArray(value) ? value : [value];
  }

  function vectorFrom(arrayValue, fallback) {
    if (!Array.isArray(arrayValue) || arrayValue.length < 2) return fallback.clone();
    return new THREE.Vector3(Number(arrayValue[0]) || 0, Number(arrayValue[1]) || 0, Number(arrayValue[2]) || 0);
  }

  function degreesToRadians(degrees) {
    return (Number(degrees) || 0) * Math.PI / 180;
  }

  function easeInOutCubic(progress) {
    return progress < 0.5 ? 4 * progress * progress * progress : 1 - Math.pow(-2 * progress + 2, 3) / 2;
  }

  /** World-space center of an object id, or the point itself if given [x,y,z]. */
  function resolvePoint(pointOrObjectId) {
    if (Array.isArray(pointOrObjectId)) return vectorFrom(pointOrObjectId, new THREE.Vector3());
    const objectRecord = explainerState.objectRecordsById.get(pointOrObjectId);
    if (!objectRecord) return null;
    const boundingBox = new THREE.Box3().setFromObject(objectRecord.mesh);
    if (boundingBox.isEmpty()) return objectRecord.mesh.getWorldPosition(new THREE.Vector3());
    return boundingBox.getCenter(new THREE.Vector3());
  }

  // ─── Expressions (live sliders) ─────────────────────────────────────────
  // A small math parser, so scenes can say "lr * 4" without running code.

  const expressionFunctions = {
    sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan,
    sqrt: Math.sqrt, abs: Math.abs, exp: Math.exp, ln: Math.log, log: Math.log, log2: Math.log2,
    log10: Math.log10, floor: Math.floor, ceil: Math.ceil, round: Math.round, sign: Math.sign,
    min: Math.min, max: Math.max, pow: Math.pow,
    sigmoid: (value) => 1 / (1 + Math.exp(-value)),
  };
  const expressionConstants = { pi: Math.PI, e: Math.E };
  const compiledExpressionsBySource = new Map();

  function tokenizeExpression(expressionSource) {
    const tokenPattern = /\s*(?:(\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)|([A-Za-z_][A-Za-z_0-9]*)|(\*\*|[-+*\/^%(),]))/y;
    const expressionTokens = [];
    tokenPattern.lastIndex = 0;
    while (tokenPattern.lastIndex < expressionSource.length) {
      if (/^\s*$/.test(expressionSource.slice(tokenPattern.lastIndex))) break;
      const tokenMatch = tokenPattern.exec(expressionSource);
      if (!tokenMatch) throw new Error('unexpected character');
      if (tokenMatch[1] !== undefined) expressionTokens.push({ kind: 'number', value: Number(tokenMatch[1]) });
      else if (tokenMatch[2] !== undefined) expressionTokens.push({ kind: 'name', value: tokenMatch[2] });
      else expressionTokens.push({ kind: 'symbol', value: tokenMatch[3] === '**' ? '^' : tokenMatch[3] });
    }
    return expressionTokens;
  }

  /** Returns a function (variableLookup) => number, or throws on bad syntax. */
  function parseExpression(expressionSource) {
    if (expressionSource.length > 400) throw new Error('expression too long');
    const expressionTokens = tokenizeExpression(expressionSource);
    let tokenIndex = 0;
    const peekToken = () => expressionTokens[tokenIndex];
    const isSymbol = (symbolText) => peekToken() && peekToken().kind === 'symbol' && peekToken().value === symbolText;
    const expectSymbol = (symbolText) => {
      if (!isSymbol(symbolText)) throw new Error('expected ' + symbolText);
      tokenIndex++;
    };

    function parseSum() {
      let leftSide = parseProduct();
      while (isSymbol('+') || isSymbol('-')) {
        const operatorText = expressionTokens[tokenIndex++].value;
        const leftOperand = leftSide;
        const rightOperand = parseProduct();
        leftSide = operatorText === '+'
          ? (lookup) => leftOperand(lookup) + rightOperand(lookup)
          : (lookup) => leftOperand(lookup) - rightOperand(lookup);
      }
      return leftSide;
    }

    function startsOperand() {
      const token = peekToken();
      return token && (token.kind !== 'symbol' || token.value === '(');
    }

    function parseProduct() {
      let leftSide = parseUnary();
      while (isSymbol('*') || isSymbol('/') || isSymbol('%') || startsOperand()) {
        // "2x" and "2(x + 1)" mean multiplication.
        const operatorText = startsOperand() ? '*' : expressionTokens[tokenIndex++].value;
        const leftOperand = leftSide;
        const rightOperand = parseUnary();
        if (operatorText === '*') leftSide = (lookup) => leftOperand(lookup) * rightOperand(lookup);
        else if (operatorText === '/') leftSide = (lookup) => leftOperand(lookup) / rightOperand(lookup);
        else leftSide = (lookup) => leftOperand(lookup) % rightOperand(lookup);
      }
      return leftSide;
    }

    function parseUnary() {
      if (isSymbol('-')) { tokenIndex++; const operand = parseUnary(); return (lookup) => -operand(lookup); }
      if (isSymbol('+')) { tokenIndex++; return parseUnary(); }
      return parsePower();
    }

    function parsePower() {
      const base = parsePrimary();
      if (isSymbol('^')) {
        tokenIndex++;
        const exponent = parseUnary();
        return (lookup) => Math.pow(base(lookup), exponent(lookup));
      }
      return base;
    }

    function parsePrimary() {
      const token = peekToken();
      if (!token) throw new Error('unexpected end');
      if (token.kind === 'number') { tokenIndex++; const numberValue = token.value; return () => numberValue; }
      if (token.kind === 'name') {
        tokenIndex++;
        const name = token.value;
        if (isSymbol('(')) {
          const mathFunction = expressionFunctions[name.toLowerCase()];
          if (!mathFunction) throw new Error('unknown function ' + name);
          tokenIndex++;
          const argumentParsers = [];
          if (!isSymbol(')')) {
            argumentParsers.push(parseSum());
            while (isSymbol(',')) { tokenIndex++; argumentParsers.push(parseSum()); }
          }
          expectSymbol(')');
          return (lookup) => mathFunction(...argumentParsers.map((argumentParser) => argumentParser(lookup)));
        }
        return (lookup) => {
          const variableValue = lookup(name);
          if (typeof variableValue === 'number') return variableValue;
          const constantValue = expressionConstants[name.toLowerCase()];
          return constantValue === undefined ? NaN : constantValue;
        };
      }
      if (token.value === '(') {
        tokenIndex++;
        const innerExpression = parseSum();
        expectSymbol(')');
        return innerExpression;
      }
      throw new Error('unexpected ' + token.value);
    }

    const parsedExpression = parseSum();
    if (tokenIndex !== expressionTokens.length) throw new Error('unexpected ' + peekToken().value);
    return parsedExpression;
  }

  /** A number, or an expression string evaluated with the current variables
      (plus `extraVariables`, e.g. { x } while plotting). NaN if invalid. */
  function evaluateNumber(numberOrExpression, extraVariables) {
    if (typeof numberOrExpression === 'number') return numberOrExpression;
    if (typeof numberOrExpression !== 'string') return NaN;
    const expressionSource = numberOrExpression.trim();
    if (!compiledExpressionsBySource.has(expressionSource)) {
      let compiledExpression = null;
      try { compiledExpression = parseExpression(expressionSource); } catch (parseError) { compiledExpression = null; }
      compiledExpressionsBySource.set(expressionSource, compiledExpression);
    }
    const compiledExpression = compiledExpressionsBySource.get(expressionSource);
    if (!compiledExpression) return NaN;
    const variableLookup = (name) =>
      (extraVariables && typeof extraVariables[name] === 'number') ? extraVariables[name] : explainerState.variables[name];
    try { return Number(compiledExpression(variableLookup)); } catch (evaluationError) { return NaN; }
  }

  /** 0.1 → "0.1", 1234.5 → "1,235", 0.000123 → "0.000123". */
  function formatLiveNumber(numberValue) {
    if (!Number.isFinite(numberValue)) return numberValue > 0 ? '∞' : numberValue < 0 ? '−∞' : '?';
    if (Math.abs(numberValue) >= 100) return Math.round(numberValue).toLocaleString('en-US');
    return String(Number(numberValue.toPrecision(3)));
  }

  /** Replaces each [[expression]] with its current value. */
  function fillLiveValues(templateText) {
    return String(templateText).replace(/\[\[([^\]]{1,200})\]\]/g, (wholeMatch, expressionSource) => formatLiveNumber(evaluateNumber(expressionSource)));
  }

  function containsLiveValues(templateText) {
    return typeof templateText === 'string' && templateText.includes('[[');
  }

  // ─── Equations (KaTeX) ──────────────────────────────────────────────────

  /** Typesets LaTeX into the element; falls back to the raw text. Only
      KaTeX's safe subset runs ("trust" stays off, so no links or HTML). */
  function renderMath(targetElement, latexSource, isDisplayMode) {
    try {
      if (!window.katex) throw new Error('KaTeX missing');
      window.katex.render(String(latexSource), targetElement, { displayMode: isDisplayMode, throwOnError: false, trust: false });
    } catch (mathError) {
      targetElement.textContent = String(latexSource);
    }
  }

  // ─── Building objects ───────────────────────────────────────────────────

  function makeGeometry(objectDescription) {
    const shape = String(objectDescription.shape || 'box').toLowerCase();
    const radius = Number(objectDescription.radius) || 1;
    const height = Number(objectDescription.height) || 1;

    switch (shape) {
      case 'sphere':
        return new THREE.SphereGeometry(radius, 48, 32);
      case 'cylinder':
        return new THREE.CylinderGeometry(
          Number(objectDescription.radiusTop ?? radius),
          Number(objectDescription.radiusBottom ?? radius),
          height, 48, 1, Boolean(objectDescription.openEnded)
        );
      case 'cone':
        return new THREE.ConeGeometry(radius, height, 48);
      case 'torus':
        return new THREE.TorusGeometry(radius, Number(objectDescription.tube) || radius * 0.25, 24, 72);
      case 'lathe': {
        const profilePoints = asArray(objectDescription.profile)
          .filter((profilePoint) => Array.isArray(profilePoint) && profilePoint.length >= 2)
          .map((profilePoint) => new THREE.Vector2(Math.max(0, Number(profilePoint[0])), Number(profilePoint[1])));
        if (profilePoints.length < 2) return new THREE.SphereGeometry(radius, 32, 16);
        return new THREE.LatheGeometry(profilePoints, 72);
      }
      case 'tube': {
        const tubePoints = asArray(objectDescription.points).map((point) => vectorFrom(point, new THREE.Vector3()));
        if (tubePoints.length < 2) return new THREE.CylinderGeometry(0.05, 0.05, 1, 12);
        const tubeCurve = tubePoints.length === 2
          ? new THREE.LineCurve3(tubePoints[0], tubePoints[1])
          : new THREE.CatmullRomCurve3(tubePoints, false, 'catmullrom', 0.2);
        return new THREE.TubeGeometry(tubeCurve, 96, Number(objectDescription.radius) || 0.08, 14, false);
      }
      case 'line': {
        // Straight segments (no smoothing), so graph data and axes stay exact.
        const linePoints = objectDescription.plot
          ? computePlotPoints(objectDescription.plot)
          : asArray(objectDescription.points).map((point) => vectorFrom(point, new THREE.Vector3()));
        if (linePoints.length < 2) return new THREE.CylinderGeometry(0.02, 0.02, 0.01, 6);
        const linePath = new THREE.CurvePath();
        for (let pointIndex = 1; pointIndex < linePoints.length; pointIndex++) {
          linePath.add(new THREE.LineCurve3(linePoints[pointIndex - 1], linePoints[pointIndex]));
        }
        const lineWidth = Number(objectDescription.width) || 0.06;
        return new THREE.TubeGeometry(linePath, Math.max(32, linePoints.length * 6), lineWidth / 2, 8, false);
      }
      case 'gear': {
        // A flat gear with real teeth, extruded to "thickness", facing +z.
        const toothCount = Math.max(6, Math.min(60, Math.round(Number(objectDescription.teeth) || 12)));
        const outerRadius = radius;
        const rootRadius = Number(objectDescription.innerRadius) || outerRadius * 0.8;
        const holeRadius = Number(objectDescription.holeRadius) || outerRadius * 0.22;
        const gearOutline = new THREE.Shape();
        for (let toothIndex = 0; toothIndex < toothCount; toothIndex++) {
          const toothAngle = (toothIndex / toothCount) * Math.PI * 2;
          const quarterPitch = (Math.PI * 2 / toothCount) / 4;
          // root → flank up → tooth top → flank down, for each tooth
          const outlineAngles = [
            [toothAngle - quarterPitch * 1.6, rootRadius],
            [toothAngle - quarterPitch * 0.7, outerRadius],
            [toothAngle + quarterPitch * 0.7, outerRadius],
            [toothAngle + quarterPitch * 1.6, rootRadius],
          ];
          outlineAngles.forEach(([pointAngle, pointRadius], pointIndex) => {
            const pointX = Math.cos(pointAngle) * pointRadius;
            const pointY = Math.sin(pointAngle) * pointRadius;
            if (toothIndex === 0 && pointIndex === 0) gearOutline.moveTo(pointX, pointY);
            else gearOutline.lineTo(pointX, pointY);
          });
        }
        gearOutline.closePath();
        const centerHole = new THREE.Path();
        centerHole.absarc(0, 0, holeRadius, 0, Math.PI * 2, true);
        gearOutline.holes.push(centerHole);
        const gearThickness = Number(objectDescription.thickness) || outerRadius * 0.3;
        const gearGeometry = new THREE.ExtrudeGeometry(gearOutline, { depth: gearThickness, bevelEnabled: false, curveSegments: 24 });
        gearGeometry.translate(0, 0, -gearThickness / 2);
        return gearGeometry;
      }
      case 'capsule':
        // A cylinder with rounded ends: cells, pills, pistons, bacteria.
        return new THREE.CapsuleGeometry(radius, Math.max(0, height - radius * 2), 12, 32);
      case 'spring': {
        // A coil around the y axis: springs, coils, DNA backbones, wire windings.
        const coilCount = Number(objectDescription.coils) || 6;
        const springHeight = height;
        const helixCurve = new THREE.Curve();
        helixCurve.getPoint = (curveProgress, targetVector = new THREE.Vector3()) => targetVector.set(
          Math.cos(curveProgress * coilCount * Math.PI * 2) * radius,
          curveProgress * springHeight - springHeight / 2,
          Math.sin(curveProgress * coilCount * Math.PI * 2) * radius
        );
        return new THREE.TubeGeometry(helixCurve, Math.round(coilCount * 40), Number(objectDescription.wireRadius) || radius * 0.08, 10, false);
      }
      case 'rect': {
        const rectSize = asArray(objectDescription.size);
        return new THREE.PlaneGeometry(Number(rectSize[0]) || 1, Number(rectSize[1]) || 1);
      }
      case 'circle':
        return new THREE.CircleGeometry(radius, 64);
      case 'ring':
        return new THREE.RingGeometry(
          Number(objectDescription.innerRadius) || radius * 0.6,
          Number(objectDescription.outerRadius) || radius, 64
        );
      case 'box':
      default: {
        const boxSize = asArray(objectDescription.size);
        return new THREE.BoxGeometry(Number(boxSize[0]) || 1, Number(boxSize[1]) || 1, Number(boxSize[2]) || 1);
      }
    }
  }

  /** A text card: an HTML box anchored to a point in the scene. */
  function makeCardElement(objectDescription) {
    const cardElement = document.createElement('div');
    // "code": true shows the text as code (monospace, line breaks kept).
    cardElement.className = 'scene-card' + (objectDescription.code ? ' is-code' : '');
    // Code keeps its line breaks, so a code card grows to fit its longest line.
    if (objectDescription.code) {
      cardElement.style.minWidth = (Number(objectDescription.width) || 220) + 'px';
      cardElement.style.maxWidth = '520px';
    } else {
      cardElement.style.width = (Number(objectDescription.width) || 220) + 'px';
    }
    if (objectDescription.color) cardElement.style.setProperty('--card-accent', objectDescription.color);
    labelLayerElement.appendChild(cardElement);
    return cardElement;
  }

  /** Fills a card with its title, equation, and text (live values filled in). */
  function renderCardContent(objectRecord) {
    const cardContent = objectRecord.cardContent;
    const cardContentElement = document.createElement('div');
    cardContentElement.className = 'scene-card-content';
    if (cardContent.title) {
      const cardTitleElement = document.createElement('div');
      cardTitleElement.className = 'scene-card-title';
      cardTitleElement.textContent = fillLiveValues(cardContent.title);
      cardContentElement.appendChild(cardTitleElement);
    }
    if (cardContent.math) {
      const cardMathElement = document.createElement('div');
      cardMathElement.className = 'scene-card-math';
      renderMath(cardMathElement, fillLiveValues(cardContent.math), true);
      cardContentElement.appendChild(cardMathElement);
    }
    if (cardContent.text) {
      const cardBodyElement = document.createElement('div');
      cardBodyElement.className = 'scene-card-body';
      cardBodyElement.textContent = fillLiveValues(cardContent.text);
      cardContentElement.appendChild(cardBodyElement);
    }
    objectRecord.cardElement.replaceChildren(cardContentElement);
  }

  function cardContentHasLiveValues(cardContent) {
    return containsLiveValues(cardContent.title) || containsLiveValues(cardContent.text) || containsLiveValues(cardContent.math);
  }

  // ─── Plots and live bindings ────────────────────────────────────────────

  /** Points for a line's "plot": y = f(x) sampled over [from, to], or the
      path of repeatedly applying "next" to x (like gradient descent steps).
      Graph units map to the scene through origin + x * unit. */
  function computePlotPoints(plotDescription) {
    const plotOrigin = asArray(plotDescription.origin);
    const plotUnit = asArray(plotDescription.unit);
    const originX = Number(plotOrigin[0]) || 0;
    const originY = Number(plotOrigin[1]) || 0;
    const unitX = Number(plotUnit[0]) || 1;
    const unitY = Number(plotUnit[1] ?? plotUnit[0]) || 1;
    // Clamp far-off values (a diverging run) so geometry stays sane.
    const clampToScene = (sceneCoordinate) => Math.max(-60, Math.min(60, sceneCoordinate));
    const plotPoints = [];
    const addGraphPoint = (graphX, graphY) => {
      if (Number.isFinite(graphX) && Number.isFinite(graphY)) {
        plotPoints.push(new THREE.Vector3(clampToScene(originX + graphX * unitX), clampToScene(originY + graphY * unitY), 0));
      }
    };

    if (plotDescription.iterate && typeof plotDescription.iterate === 'object') {
      const iterateDescription = plotDescription.iterate;
      const iterationCount = Math.max(1, Math.min(200, Math.round(evaluateNumber(iterateDescription.count ?? 10)) || 10));
      let currentX = evaluateNumber(iterateDescription.start ?? 0);
      for (let iterationIndex = 0; iterationIndex <= iterationCount && Number.isFinite(currentX); iterationIndex++) {
        addGraphPoint(currentX, evaluateNumber(plotDescription.y ?? 'x', { x: currentX }));
        currentX = evaluateNumber(iterateDescription.next, { x: currentX });
        if (Math.abs(currentX) > 1e6) break;
      }
      return plotPoints;
    }

    const fromX = evaluateNumber(plotDescription.from ?? -5);
    const toX = evaluateNumber(plotDescription.to ?? 5);
    if (!Number.isFinite(fromX) || !Number.isFinite(toX)) return plotPoints;
    const sampleCount = Math.max(2, Math.min(400, Math.round(Number(plotDescription.samples)) || 80));
    for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
      const graphX = fromX + (toX - fromX) * sampleIndex / (sampleCount - 1);
      addGraphPoint(graphX, evaluateNumber(plotDescription.y, { x: graphX }));
    }
    return plotPoints;
  }

  /** Rebuilds a plotted line (and its point markers) from the current variables. */
  function rebuildPlot(objectRecord) {
    const objectDescription = objectRecord.description;
    const oldGeometry = objectRecord.mesh.geometry;
    objectRecord.mesh.geometry = makeGeometry(objectDescription);
    if (oldGeometry) oldGeometry.dispose();

    for (const markerMesh of objectRecord.plotMarkerMeshes) {
      objectRecord.mesh.remove(markerMesh);
      markerMesh.geometry.dispose();
    }
    objectRecord.plotMarkerMeshes = [];
    const markerRadius = Number(objectDescription.plot.markers) || 0;
    if (markerRadius <= 0) return;
    for (const plotPoint of computePlotPoints(objectDescription.plot)) {
      const markerGeometry = explainerState.isTwoDimensional
        ? new THREE.CircleGeometry(markerRadius, 24)
        : new THREE.SphereGeometry(markerRadius, 20, 14);
      // Shares the line's material, so markers fade and highlight with it.
      const markerMesh = new THREE.Mesh(markerGeometry, objectRecord.material);
      markerMesh.position.copy(plotPoint);
      markerMesh.position.z += 0.01;
      objectRecord.mesh.add(markerMesh);
      objectRecord.plotMarkerMeshes.push(markerMesh);
    }
  }

  /** Re-applies every expression after a slider moves (and after resets). */
  function applyVariableBindings() {
    for (const objectRecord of explainerState.objectRecordsById.values()) {
      const objectDescription = objectRecord.description;
      const bindings = objectDescription.bind;
      if (bindings && typeof bindings === 'object') {
        if (Array.isArray(bindings.position)) {
          for (let axisIndex = 0; axisIndex < 3; axisIndex++) {
            if (bindings.position[axisIndex] === undefined || bindings.position[axisIndex] === null) continue;
            const axisValue = evaluateNumber(bindings.position[axisIndex]);
            if (Number.isFinite(axisValue)) objectRecord.mesh.position.setComponent(axisIndex, Math.max(-100, Math.min(100, axisValue)));
          }
        }
        if (bindings.scale !== undefined) {
          const scaleExpressions = asArray(bindings.scale);
          const scaleValues = [0, 1, 2].map((axisIndex) => evaluateNumber(scaleExpressions[axisIndex] ?? scaleExpressions[0]));
          if (scaleValues.every(Number.isFinite)) {
            objectRecord.mesh.scale.set(...scaleValues.map((scaleValue) => Math.max(0.0001, Math.min(100, scaleValue))));
          }
        }
        if (bindings.opacity !== undefined) {
          const opacityValue = evaluateNumber(bindings.opacity);
          if (Number.isFinite(opacityValue)) objectRecord.baseOpacity = Math.max(0, Math.min(1, opacityValue));
        }
      }
      if (objectDescription.plot && objectRecord.material) rebuildPlot(objectRecord);
      if (objectRecord.cardElement && cardContentHasLiveValues(objectRecord.cardContent)) renderCardContent(objectRecord);
    }
    for (const labelRecord of explainerState.labelRecordsByKey.values()) {
      if (containsLiveValues(labelRecord.labelText) || containsLiveValues(labelRecord.labelMath)) renderLabelContent(labelRecord);
    }
    refreshObjectTargetOpacities();
  }

  // ─── Live sliders ───────────────────────────────────────────────────────

  const sliderPanelElement = document.getElementById('slider-panel');
  // Dragging a slider shouldn't also pan or rotate the scene.
  sliderPanelElement.addEventListener('pointerdown', (pointerEvent) => pointerEvent.stopPropagation());
  sliderPanelElement.addEventListener('wheel', (wheelEvent) => wheelEvent.stopPropagation());

  function showSlider(sliderAction) {
    const variableName = String(sliderAction.id ?? sliderAction.variable ?? '');
    if (!/^[A-Za-z_][A-Za-z_0-9]{0,30}$/.test(variableName)) return;
    let minimumValue = Number(sliderAction.min);
    let maximumValue = Number(sliderAction.max);
    if (!Number.isFinite(minimumValue)) minimumValue = 0;
    if (!Number.isFinite(maximumValue) || maximumValue <= minimumValue) maximumValue = minimumValue + 1;
    const stepSize = Number(sliderAction.step) > 0 ? Number(sliderAction.step) : (maximumValue - minimumValue) / 100;
    const requestedValue = Number(sliderAction.value);
    const startingValue = Number.isFinite(requestedValue)
      ? requestedValue
      : (typeof explainerState.variables[variableName] === 'number' ? explainerState.variables[variableName] : minimumValue);
    explainerState.variables[variableName] = Math.max(minimumValue, Math.min(maximumValue, startingValue));

    if (!sliderPanelElement.querySelector('.slider-hint')) {
      const sliderHintElement = document.createElement('div');
      sliderHintElement.className = 'slider-hint';
      sliderHintElement.textContent = 'Try it: drag to change';
      sliderPanelElement.appendChild(sliderHintElement);
    }
    let sliderRowElement = sliderPanelElement.querySelector('[data-variable="' + variableName + '"]');
    if (!sliderRowElement) {
      sliderRowElement = document.createElement('div');
      sliderRowElement.className = 'slider-row';
      sliderRowElement.dataset.variable = variableName;
      sliderRowElement.innerHTML = '<div class="slider-row-header"><span class="slider-name"></span><span class="slider-value"></span></div><input type="range">';
      sliderPanelElement.appendChild(sliderRowElement);
      const sliderInput = sliderRowElement.querySelector('input');
      sliderInput.addEventListener('input', () => {
        explainerState.variables[variableName] = Number(sliderInput.value);
        sliderRowElement.querySelector('.slider-value').textContent = formatLiveNumber(Number(sliderInput.value));
        applyVariableBindings();
      });
    }
    sliderRowElement.querySelector('.slider-name').textContent = String(sliderAction.label || variableName);
    const sliderInput = sliderRowElement.querySelector('input');
    sliderInput.min = String(minimumValue);
    sliderInput.max = String(maximumValue);
    sliderInput.step = String(stepSize);
    sliderInput.value = String(explainerState.variables[variableName]);
    sliderRowElement.querySelector('.slider-value').textContent = formatLiveNumber(explainerState.variables[variableName]);
    sliderPanelElement.hidden = false;
  }

  function hideSliders() {
    sliderPanelElement.hidden = true;
    sliderPanelElement.replaceChildren();
  }

  /** Back to the scene's starting values ("variables" in the setup). */
  function resetVariables() {
    explainerState.variables = Object.create(null);
    const startingVariables = explainerState.sceneDescription && explainerState.sceneDescription.variables;
    if (startingVariables && typeof startingVariables === 'object') {
      for (const [variableName, startingValue] of Object.entries(startingVariables)) {
        if (/^[A-Za-z_][A-Za-z_0-9]{0,30}$/.test(variableName) && Number.isFinite(Number(startingValue))) {
          explainerState.variables[variableName] = Number(startingValue);
        }
      }
    }
  }

  function buildSceneObject(objectDescription, isAddedByStep) {
    const shape = String(objectDescription.shape || 'box').toLowerCase();
    const objectId = String(objectDescription.id || ('object-' + explainerState.objectRecordsById.size));
    // Adding the same id twice (e.g. replaying a step) keeps the first one.
    if (explainerState.objectRecordsById.has(objectId)) return;
    const isFlatOrOpenShape = ['lathe', 'rect', 'circle', 'ring'].includes(shape) || objectDescription.openEnded;
    const baseOpacity = objectDescription.opacity === undefined ? 1 : Math.max(0, Math.min(1, Number(objectDescription.opacity)));

    const material = explainerState.isTwoDimensional
      ? new THREE.MeshBasicMaterial({ color: objectDescription.color || '#8fa3c7', transparent: true, side: THREE.DoubleSide })
      : new THREE.MeshStandardMaterial({
          color: objectDescription.color || '#8fa3c7',
          metalness: objectDescription.metalness === undefined ? 0.25 : Number(objectDescription.metalness),
          roughness: objectDescription.roughness === undefined ? 0.45 : Number(objectDescription.roughness),
          transparent: true,
          side: isFlatOrOpenShape ? THREE.DoubleSide : THREE.FrontSide,
          emissive: new THREE.Color(0x000000),
        });

    const isCard = shape === 'card';
    // Cards are HTML, so their "mesh" is just an empty anchor point.
    const mesh = isCard ? new THREE.Object3D() : new THREE.Mesh(makeGeometry(objectDescription), material);
    mesh.position.copy(vectorFrom(objectDescription.position, new THREE.Vector3()));
    const rotationInDegrees = asArray(objectDescription.rotation);
    mesh.rotation.set(
      degreesToRadians(rotationInDegrees[0]),
      degreesToRadians(rotationInDegrees[1]),
      degreesToRadians(rotationInDegrees[2])
    );
    if (objectDescription.scale !== undefined) {
      const scaleValues = asArray(objectDescription.scale);
      mesh.scale.set(Number(scaleValues[0]) || 1, Number(scaleValues[1] ?? scaleValues[0]) || 1, Number(scaleValues[2] ?? scaleValues[0]) || 1);
    }

    const isInitiallyShown = !objectDescription.hidden;
    // Lines with "drawn": false start invisible and are traced by "draw".
    const initialDrawProgress = objectDescription.drawn === false ? 0 : 1;
    const objectRecord = {
      id: objectId,
      description: objectDescription,
      mesh,
      material: isCard ? null : material,
      cardElement: isCard ? makeCardElement(objectDescription) : null,
      /** A card's title, equation, and text; "update" changes them. */
      cardContent: isCard ? initialCardContent(objectDescription) : null,
      plotMarkerMeshes: [],
      isAddedByStep: Boolean(isAddedByStep),
      initialColor: new THREE.Color(objectDescription.color || '#8fa3c7'),
      currentBaseColor: new THREE.Color(objectDescription.color || '#8fa3c7'),
      initialPosition: mesh.position.clone(),
      initialRotation: mesh.rotation.clone(),
      initialDrawProgress,
      drawProgress: initialDrawProgress,
      drawTargetProgress: initialDrawProgress,
      drawSecondsTotal: 1.5,
      moveTween: null,
      revolveCenter: null,
      revolveAxis: 'y',
      revolveTurnsPerSecond: 0,
      initialBaseOpacity: baseOpacity,
      baseOpacity,
      isShown: isInitiallyShown,
      // Objects added during a step fade in rather than popping into view.
      currentOpacity: isInitiallyShown && !isAddedByStep ? baseOpacity : 0,
      targetOpacity: isInitiallyShown ? baseOpacity : 0,
      highlightColor: null,
      highlightLight: null,
      spinAxis: null,
      spinTurnsPerSecond: 0,
    };
    if (!isCard) {
      material.opacity = objectRecord.currentOpacity;
      if (initialDrawProgress < 1) mesh.geometry.setDrawRange(0, 0);
      if (objectDescription.plot && Number(objectDescription.plot.markers) > 0) rebuildPlot(objectRecord);
    } else {
      material.dispose();
      renderCardContent(objectRecord);
    }
    mesh.visible = objectRecord.currentOpacity > 0.01;
    explainerState.sceneObjectsGroup.add(mesh);
    explainerState.objectRecordsById.set(objectRecord.id, objectRecord);
  }

  function initialCardContent(objectDescription) {
    return { title: objectDescription.title, text: objectDescription.text, math: objectDescription.math };
  }

  function disposeSceneObject(objectRecord) {
    clearHighlight(objectRecord);
    objectRecord.plotMarkerMeshes.forEach((markerMesh) => markerMesh.geometry.dispose());
    explainerState.sceneObjectsGroup.remove(objectRecord.mesh);
    if (objectRecord.mesh.geometry) objectRecord.mesh.geometry.dispose();
    if (objectRecord.material) objectRecord.material.dispose();
    if (objectRecord.cardElement) objectRecord.cardElement.remove();
    explainerState.objectRecordsById.delete(objectRecord.id);
  }

  /** Recomputes every object's target opacity from shown/focus/cutaway state. */
  function refreshObjectTargetOpacities() {
    const focusedObjectIds = explainerState.focusedObjectIds;
    for (const objectRecord of explainerState.objectRecordsById.values()) {
      if (!objectRecord.isShown) {
        objectRecord.targetOpacity = 0;
      } else if (focusedObjectIds && !focusedObjectIds.has(objectRecord.id)) {
        objectRecord.targetOpacity = Math.min(objectRecord.baseOpacity, 0.14);
      } else {
        objectRecord.targetOpacity = objectRecord.baseOpacity;
      }
    }
  }

  // ─── Labels ─────────────────────────────────────────────────────────────

  function renderLabelContent(labelRecord) {
    const labelTextElement = labelRecord.element.querySelector('.scene-label-text');
    if (labelRecord.labelMath) renderMath(labelTextElement, fillLiveValues(labelRecord.labelMath), false);
    else labelTextElement.textContent = fillLiveValues(labelRecord.labelText);
  }

  function showLabel(labelKey, labelText, anchorObjectId, anchorPosition, offset, labelMath) {
    let labelRecord = explainerState.labelRecordsByKey.get(labelKey);
    if (!labelRecord) {
      const labelElement = document.createElement('div');
      labelElement.className = 'scene-label';
      labelElement.innerHTML = '<div class="scene-label-text"></div><div class="scene-label-leader"></div><div class="scene-label-anchor"></div>';
      labelLayerElement.appendChild(labelElement);
      labelRecord = { element: labelElement };
      explainerState.labelRecordsByKey.set(labelKey, labelRecord);
    }
    labelRecord.labelText = String(labelText);
    labelRecord.labelMath = labelMath ? String(labelMath) : null;
    renderLabelContent(labelRecord);
    labelRecord.anchorObjectId = anchorObjectId;
    labelRecord.anchorPosition = anchorPosition;
    labelRecord.offset = offset;
    // Reading offsetWidth applies the hidden style first, so adding the
    // class right after still plays the fade-in transition.
    void labelRecord.element.offsetWidth;
    labelRecord.element.classList.add('is-visible');
  }

  function hideLabel(labelKey) {
    const labelRecord = explainerState.labelRecordsByKey.get(labelKey);
    if (labelRecord) labelRecord.element.classList.remove('is-visible');
  }

  function removeAllLabels() {
    for (const labelRecord of explainerState.labelRecordsByKey.values()) labelRecord.element.remove();
    explainerState.labelRecordsByKey.clear();
  }

  const projectedLabelPosition = new THREE.Vector3();

  function positionLabels() {
    const stageWidth = stageElement.clientWidth;
    const stageHeight = stageElement.clientHeight;
    for (const labelRecord of explainerState.labelRecordsByKey.values()) {
      let anchorPoint = null;
      if (labelRecord.anchorObjectId) {
        const objectRecord = explainerState.objectRecordsById.get(labelRecord.anchorObjectId);
        if (objectRecord && objectRecord.currentOpacity > 0.01) anchorPoint = resolvePoint(labelRecord.anchorObjectId);
      } else if (labelRecord.anchorPosition) {
        anchorPoint = labelRecord.anchorPosition.clone();
      }
      if (!anchorPoint) {
        labelRecord.element.style.display = 'none';
        continue;
      }
      if (labelRecord.offset) anchorPoint.add(labelRecord.offset);

      projectedLabelPosition.copy(anchorPoint).project(activeCamera);
      const isBehindCamera = projectedLabelPosition.z > 1;
      labelRecord.element.style.display = isBehindCamera ? 'none' : 'flex';
      // Keep the whole label inside the stage, even for anchors near an edge.
      // The label sits above its anchor, so the top needs room for its height.
      const labelHalfWidth = labelRecord.element.offsetWidth / 2 || 40;
      const labelHeight = labelRecord.element.offsetHeight || 50;
      const labelLeft = (projectedLabelPosition.x + 1) / 2 * stageWidth;
      const labelTop = (1 - projectedLabelPosition.y) / 2 * stageHeight;
      labelRecord.element.style.left = Math.max(labelHalfWidth + 6, Math.min(stageWidth - labelHalfWidth - 6, labelLeft)) + 'px';
      labelRecord.element.style.top = Math.max(labelHeight + 4, Math.min(stageHeight - 4, labelTop)) + 'px';
    }
  }

  // ─── Effects: arrows, flows, plumes ─────────────────────────────────────

  function addEffect(effect) {
    explainerState.activeEffects.push(effect);
    threeScene.add(effect.object3D);
  }

  function removeAllEffects() {
    for (const effect of explainerState.activeEffects) {
      threeScene.remove(effect.object3D);
      if (effect.dispose) effect.dispose();
    }
    explainerState.activeEffects = [];
  }

  function addArrowEffect(action, isInstant) {
    const startPoint = resolvePoint(action.from);
    const endPoint = resolvePoint(action.to);
    if (!startPoint || !endPoint) return;

    const arrowVector = new THREE.Vector3().subVectors(endPoint, startPoint);
    const arrowLength = arrowVector.length();
    if (arrowLength < 0.01) return;

    const arrowColor = new THREE.Color(action.color || '#3380ff');
    const arrowMaterial = new THREE.MeshBasicMaterial({ color: arrowColor, transparent: true, opacity: 0.95 });
    const shaftRadius = Number(action.thickness) || Math.max(0.04, arrowLength * 0.018);
    const headLength = Math.min(arrowLength * 0.3, shaftRadius * 7);
    const headRadius = shaftRadius * 2.6;

    const shaftMesh = new THREE.Mesh(new THREE.CylinderGeometry(shaftRadius, shaftRadius, arrowLength - headLength, 16), arrowMaterial);
    shaftMesh.position.y = (arrowLength - headLength) / 2;
    const headMesh = new THREE.Mesh(new THREE.ConeGeometry(headRadius, headLength, 24), arrowMaterial);
    headMesh.position.y = arrowLength - headLength / 2;

    // Built pointing up its local y axis from the origin, then rotated into place.
    const arrowGroup = new THREE.Group();
    arrowGroup.add(shaftMesh, headMesh);
    arrowGroup.position.copy(startPoint);
    arrowGroup.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), arrowVector.clone().normalize());
    arrowGroup.scale.set(1, isInstant ? 1 : 0.001, 1);

    let growProgress = isInstant ? 1 : 0;
    addEffect({
      object3D: arrowGroup,
      update(deltaSeconds) {
        if (growProgress < 1) {
          growProgress = Math.min(1, growProgress + deltaSeconds / 0.7);
          arrowGroup.scale.y = Math.max(0.001, easeInOutCubic(growProgress));
        }
      },
      dispose() {
        shaftMesh.geometry.dispose();
        headMesh.geometry.dispose();
        arrowMaterial.dispose();
      },
    });

    if (action.text) {
      const labelPosition = startPoint.clone().lerp(endPoint, 0.55);
      showLabel('arrow-' + explainerState.activeEffects.length, action.text, null, labelPosition, null);
    }
  }

  function makeParticlePoints(particleCount, colorValue, particleSize) {
    const particleGeometry = new THREE.BufferGeometry();
    particleGeometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(particleCount * 3), 3));
    particleGeometry.setAttribute('color', new THREE.BufferAttribute(new Float32Array(particleCount * 3), 3));
    const particleMaterial = new THREE.PointsMaterial({
      size: particleSize,
      map: particleTexture,
      vertexColors: true,
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      sizeAttenuation: !explainerState.isTwoDimensional,
    });
    const particlePoints = new THREE.Points(particleGeometry, particleMaterial);
    particlePoints.frustumCulled = false;
    return { particlePoints, particleGeometry, particleMaterial, baseColor: new THREE.Color(colorValue) };
  }

  function addFlowEffect(action) {
    const pathPoints = asArray(action.path).map(resolvePoint).filter(Boolean);
    if (pathPoints.length < 2) return;

    const flowCurve = pathPoints.length === 2
      ? new THREE.LineCurve3(pathPoints[0], pathPoints[1])
      : new THREE.CatmullRomCurve3(pathPoints, false, 'catmullrom', 0.15);
    const curveLength = Math.max(0.1, flowCurve.getLength());
    const particleCount = Math.max(6, Math.min(160, Number(action.count) || Math.round(curveLength * 6)));
    const unitsPerSecond = Number(action.speed) || 1.5;
    const flowColor = action.color || '#7cc4ff';

    const { particlePoints, particleGeometry, particleMaterial, baseColor } =
      makeParticlePoints(particleCount, flowColor, explainerState.isTwoDimensional ? 9 : 0.22);
    // Flows usually run inside pipes and vessels; drawing them on top makes
    // them glow through the walls instead of being hidden.
    particleMaterial.depthTest = false;
    particlePoints.renderOrder = 10;

    // A faint guide line shows the route even between particles.
    const guideMaterial = new THREE.LineBasicMaterial({ color: flowColor, transparent: true, opacity: 0.22 });
    const guideLine = new THREE.Line(new THREE.BufferGeometry().setFromPoints(flowCurve.getPoints(80)), guideMaterial);

    const flowGroup = new THREE.Group();
    flowGroup.add(guideLine, particlePoints);

    const particleProgress = Array.from({ length: particleCount }, (_, particleIndex) => particleIndex / particleCount);
    const positionAttribute = particleGeometry.getAttribute('position');
    const colorAttribute = particleGeometry.getAttribute('color');
    const pointOnCurve = new THREE.Vector3();

    addEffect({
      object3D: flowGroup,
      update(deltaSeconds) {
        for (let particleIndex = 0; particleIndex < particleCount; particleIndex++) {
          particleProgress[particleIndex] = (particleProgress[particleIndex] + deltaSeconds * unitsPerSecond / curveLength) % 1;
          flowCurve.getPointAt(particleProgress[particleIndex], pointOnCurve);
          positionAttribute.setXYZ(particleIndex, pointOnCurve.x, pointOnCurve.y, pointOnCurve.z);
          // Fade in at the start of the path and out at the end.
          const edgeFade = Math.min(1, particleProgress[particleIndex] * 8, (1 - particleProgress[particleIndex]) * 8);
          colorAttribute.setXYZ(particleIndex, baseColor.r * edgeFade, baseColor.g * edgeFade, baseColor.b * edgeFade);
        }
        positionAttribute.needsUpdate = true;
        colorAttribute.needsUpdate = true;
      },
      dispose() {
        particleGeometry.dispose();
        particleMaterial.dispose();
        guideLine.geometry.dispose();
        guideMaterial.dispose();
      },
    });
  }

  function addPlumeEffect(action) {
    const originPoint = typeof action.from === 'string'
      ? (() => {
          // Emit from the bottom of the object's bounds along the direction.
          const objectRecord = explainerState.objectRecordsById.get(action.from);
          if (!objectRecord) return null;
          const boundingBox = new THREE.Box3().setFromObject(objectRecord.mesh);
          const center = boundingBox.getCenter(new THREE.Vector3());
          const plumeDirection = vectorFrom(action.direction, new THREE.Vector3(0, -1, 0)).normalize();
          const halfSize = boundingBox.getSize(new THREE.Vector3()).multiplyScalar(0.5);
          return center.add(new THREE.Vector3(
            plumeDirection.x * halfSize.x, plumeDirection.y * halfSize.y, plumeDirection.z * halfSize.z
          ));
        })()
      : resolvePoint(action.from);
    if (!originPoint) return;

    const plumeDirection = vectorFrom(action.direction, new THREE.Vector3(0, -1, 0)).normalize();
    const plumeLength = Number(action.length) || 4;
    const plumeSpread = Number(action.spread) || 0.3;
    const particleCount = Math.max(40, Math.min(400, Number(action.count) || 220));
    const hotColor = new THREE.Color('#fff4d6');
    const coolColor = new THREE.Color(action.color || '#ff9a3c');

    const { particlePoints, particleGeometry, particleMaterial } =
      makeParticlePoints(particleCount, action.color || '#ff9a3c', explainerState.isTwoDimensional ? 12 : 0.32);

    // Two perpendicular vectors to spread particles around the plume axis.
    const sideVectorA = new THREE.Vector3(1, 0, 0);
    if (Math.abs(plumeDirection.dot(sideVectorA)) > 0.9) sideVectorA.set(0, 0, 1);
    sideVectorA.cross(plumeDirection).normalize();
    const sideVectorB = new THREE.Vector3().crossVectors(plumeDirection, sideVectorA).normalize();

    const particleAges = new Float32Array(particleCount);
    const particleLifetimes = new Float32Array(particleCount);
    const particleVelocities = Array.from({ length: particleCount }, () => new THREE.Vector3());
    const particlePositions = Array.from({ length: particleCount }, () => originPoint.clone());

    function respawnParticle(particleIndex) {
      particleLifetimes[particleIndex] = 0.5 + Math.random() * 0.5;
      particleAges[particleIndex] = 0;
      const sideAngle = Math.random() * Math.PI * 2;
      const sideAmount = Math.random() * plumeSpread;
      particleVelocities[particleIndex]
        .copy(plumeDirection)
        .addScaledVector(sideVectorA, Math.cos(sideAngle) * sideAmount)
        .addScaledVector(sideVectorB, Math.sin(sideAngle) * sideAmount)
        .normalize()
        .multiplyScalar(plumeLength / particleLifetimes[particleIndex]);
      particlePositions[particleIndex].copy(originPoint);
    }

    for (let particleIndex = 0; particleIndex < particleCount; particleIndex++) {
      respawnParticle(particleIndex);
      particleAges[particleIndex] = Math.random() * particleLifetimes[particleIndex];
    }

    const positionAttribute = particleGeometry.getAttribute('position');
    const colorAttribute = particleGeometry.getAttribute('color');
    const blendedColor = new THREE.Color();

    addEffect({
      object3D: particlePoints,
      update(deltaSeconds) {
        for (let particleIndex = 0; particleIndex < particleCount; particleIndex++) {
          particleAges[particleIndex] += deltaSeconds;
          if (particleAges[particleIndex] >= particleLifetimes[particleIndex]) respawnParticle(particleIndex);
          const lifeProgress = particleAges[particleIndex] / particleLifetimes[particleIndex];
          const particlePosition = particlePositions[particleIndex]
            .copy(originPoint)
            .addScaledVector(particleVelocities[particleIndex], particleAges[particleIndex]);
          positionAttribute.setXYZ(particleIndex, particlePosition.x, particlePosition.y, particlePosition.z);
          // White-hot at the nozzle, then the plume color, fading to nothing.
          // Additive blending makes black fully transparent.
          blendedColor.copy(hotColor).lerp(coolColor, Math.min(1, lifeProgress * 2.2)).multiplyScalar(1 - lifeProgress);
          colorAttribute.setXYZ(particleIndex, blendedColor.r, blendedColor.g, blendedColor.b);
        }
        positionAttribute.needsUpdate = true;
        colorAttribute.needsUpdate = true;
      },
      dispose() {
        particleGeometry.dispose();
        particleMaterial.dispose();
      },
    });
  }

  // ─── Camera ─────────────────────────────────────────────────────────────

  function setCameraRigFromPosition(cameraPosition, cameraTarget) {
    const offsetFromTarget = new THREE.Vector3().subVectors(cameraPosition, cameraTarget);
    const spherical = new THREE.Spherical().setFromVector3(offsetFromTarget);
    return {
      target: cameraTarget.clone(),
      azimuthInRadians: spherical.theta,
      polarInRadians: spherical.phi,
      distance: Math.max(1, spherical.radius),
    };
  }

  /**
   * Camera rig that frames the given objects (all visible objects if none),
   * keeping the current viewing angle unless `angle` [azimuth°, elevation°]
   * is given. Lets scenes say "show me these" without computing positions.
   */
  function cameraRigFittingObjects(objectIds, angleInDegrees) {
    const objectIdsToFit = objectIds.length
      ? objectIds
      : [...explainerState.objectRecordsById.values()].filter((objectRecord) => objectRecord.isShown).map((objectRecord) => objectRecord.id);
    const fitBox = new THREE.Box3();
    for (const objectId of objectIdsToFit) {
      const objectRecord = explainerState.objectRecordsById.get(objectId);
      if (objectRecord) fitBox.expandByObject(objectRecord.mesh);
    }
    if (fitBox.isEmpty()) return null;

    const boundingSphere = fitBox.getBoundingSphere(new THREE.Sphere());
    const verticalFieldOfView = perspectiveCamera.fov * Math.PI / 180;
    const horizontalFieldOfView = 2 * Math.atan(Math.tan(verticalFieldOfView / 2) * perspectiveCamera.aspect);
    const limitingFieldOfView = Math.min(verticalFieldOfView, horizontalFieldOfView);
    const fittingDistance = boundingSphere.radius / Math.sin(limitingFieldOfView / 2) * 1.22;

    // Close-ups of small parts stay at least about a third of the way out,
    // so the surrounding model is still recognizable instead of filling the view.
    const wholeSceneBox = new THREE.Box3();
    for (const objectRecord of explainerState.objectRecordsById.values()) {
      if (objectRecord.isShown) wholeSceneBox.expandByObject(objectRecord.mesh);
    }
    const wholeSceneRadius = wholeSceneBox.isEmpty() ? 0 : wholeSceneBox.getBoundingSphere(new THREE.Sphere()).radius;
    const minimumCloseUpDistance = wholeSceneRadius / Math.sin(limitingFieldOfView / 2) * 0.38;

    const fittedRig = {
      target: boundingSphere.center.clone(),
      azimuthInRadians: cameraRig.azimuthInRadians,
      polarInRadians: cameraRig.polarInRadians,
      distance: Math.max(2, fittingDistance, minimumCloseUpDistance),
    };
    if (Array.isArray(angleInDegrees) && angleInDegrees.length >= 2) {
      fittedRig.azimuthInRadians = degreesToRadians(angleInDegrees[0]);
      // Elevation above the horizon → polar angle from straight up.
      fittedRig.polarInRadians = Math.PI / 2 - degreesToRadians(angleInDegrees[1]);
    }

    // 2D scenes zoom the flat view instead of moving closer.
    if (explainerState.isTwoDimensional) {
      const viewWidth = orthographicCamera.right - orthographicCamera.left;
      const viewHeight = orthographicCamera.top - orthographicCamera.bottom;
      const fitSize = fitBox.getSize(new THREE.Vector3());
      fittedRig.orthographicZoom = Math.max(0.3, Math.min(6, 0.9 * Math.min(viewWidth / Math.max(fitSize.x, 0.01), viewHeight / Math.max(fitSize.y, 0.01))));
    }
    return fittedRig;
  }

  function moveCamera(cameraAction, isInstant) {
    if (cameraAction.fit !== undefined) {
      const fitObjectIds = cameraAction.fit === true ? [] : asArray(cameraAction.fit).map(String);
      const fittedRig = cameraRigFittingObjects(fitObjectIds, cameraAction.angle);
      if (fittedRig) {
        cameraAction = {
          position: new THREE.Vector3().setFromSpherical(new THREE.Spherical(fittedRig.distance, fittedRig.polarInRadians, fittedRig.azimuthInRadians)).add(fittedRig.target).toArray(),
          target: fittedRig.target.toArray(),
          zoom: fittedRig.orthographicZoom,
          seconds: cameraAction.seconds,
        };
      }
    }
    const cameraTarget = vectorFrom(cameraAction.target, cameraRig.target);
    const cameraPosition = cameraAction.position
      ? vectorFrom(cameraAction.position, new THREE.Vector3())
      : null;

    const destinationRig = cameraPosition
      ? setCameraRigFromPosition(cameraPosition, cameraTarget)
      : { target: cameraTarget, azimuthInRadians: cameraRig.azimuthInRadians, polarInRadians: cameraRig.polarInRadians, distance: cameraRig.distance };
    if (cameraAction.zoom !== undefined) destinationRig.orthographicZoom = Number(cameraAction.zoom) || 1;

    if (isInstant) {
      Object.assign(cameraRig, destinationRig);
      explainerState.cameraTween = null;
      return;
    }

    // Take the short way around when changing azimuth.
    let azimuthDifference = destinationRig.azimuthInRadians - cameraRig.azimuthInRadians;
    azimuthDifference = Math.atan2(Math.sin(azimuthDifference), Math.cos(azimuthDifference));

    explainerState.cameraTween = {
      elapsedSeconds: 0,
      durationSeconds: Number(cameraAction.seconds) || 1.6,
      startTarget: cameraRig.target.clone(),
      endTarget: destinationRig.target,
      startAzimuth: cameraRig.azimuthInRadians,
      azimuthDifference,
      startPolar: cameraRig.polarInRadians,
      endPolar: destinationRig.polarInRadians,
      startDistance: cameraRig.distance,
      endDistance: destinationRig.distance,
      startZoom: cameraRig.orthographicZoom,
      endZoom: destinationRig.orthographicZoom ?? cameraRig.orthographicZoom,
    };
  }

  function updateCamera(deltaSeconds) {
    const cameraTween = explainerState.cameraTween;
    if (cameraTween) {
      cameraTween.elapsedSeconds += deltaSeconds;
      const easedProgress = easeInOutCubic(Math.min(1, cameraTween.elapsedSeconds / cameraTween.durationSeconds));
      cameraRig.target.lerpVectors(cameraTween.startTarget, cameraTween.endTarget, easedProgress);
      cameraRig.azimuthInRadians = cameraTween.startAzimuth + cameraTween.azimuthDifference * easedProgress;
      cameraRig.polarInRadians = cameraTween.startPolar + (cameraTween.endPolar - cameraTween.startPolar) * easedProgress;
      cameraRig.distance = cameraTween.startDistance + (cameraTween.endDistance - cameraTween.startDistance) * easedProgress;
      cameraRig.orthographicZoom = cameraTween.startZoom + (cameraTween.endZoom - cameraTween.startZoom) * easedProgress;
      if (easedProgress >= 1) explainerState.cameraTween = null;
    } else if (cameraRig.autoRotate && !cameraRig.isUserDragging && !explainerState.isTwoDimensional) {
      cameraRig.azimuthInRadians += deltaSeconds * 0.12;
    }

    if (explainerState.isTwoDimensional) {
      orthographicCamera.position.set(cameraRig.target.x, cameraRig.target.y, 50);
      orthographicCamera.lookAt(cameraRig.target.x, cameraRig.target.y, 0);
      orthographicCamera.zoom = cameraRig.orthographicZoom;
      orthographicCamera.updateProjectionMatrix();
      return;
    }

    cameraRig.polarInRadians = Math.max(0.15, Math.min(Math.PI - 0.15, cameraRig.polarInRadians));
    const cameraOffset = new THREE.Vector3().setFromSpherical(
      new THREE.Spherical(cameraRig.distance, cameraRig.polarInRadians, cameraRig.azimuthInRadians)
    );
    perspectiveCamera.position.copy(cameraRig.target).add(cameraOffset);
    perspectiveCamera.lookAt(cameraRig.target);
  }

  // Drag to orbit (3d) or pan (2d); scroll to zoom.
  let lastPointerPosition = null;
  stageElement.addEventListener('pointerdown', (pointerEvent) => {
    lastPointerPosition = { x: pointerEvent.clientX, y: pointerEvent.clientY };
    cameraRig.isUserDragging = true;
    explainerState.cameraTween = null;
    stageElement.setPointerCapture(pointerEvent.pointerId);
  });
  stageElement.addEventListener('pointermove', (pointerEvent) => {
    if (!lastPointerPosition) return;
    const deltaX = pointerEvent.clientX - lastPointerPosition.x;
    const deltaY = pointerEvent.clientY - lastPointerPosition.y;
    lastPointerPosition = { x: pointerEvent.clientX, y: pointerEvent.clientY };
    if (explainerState.isTwoDimensional) {
      const unitsPerPixel = (orthographicCamera.right - orthographicCamera.left) / orthographicCamera.zoom / stageElement.clientWidth;
      cameraRig.target.x -= deltaX * unitsPerPixel;
      cameraRig.target.y += deltaY * unitsPerPixel;
    } else {
      cameraRig.azimuthInRadians -= deltaX * 0.008;
      cameraRig.polarInRadians -= deltaY * 0.008;
    }
  });
  function endPointerDrag() {
    lastPointerPosition = null;
    cameraRig.isUserDragging = false;
  }
  stageElement.addEventListener('pointerup', endPointerDrag);
  stageElement.addEventListener('pointercancel', endPointerDrag);
  stageElement.addEventListener('wheel', (wheelEvent) => {
    wheelEvent.preventDefault();
    explainerState.cameraTween = null;
    const zoomFactor = Math.exp(wheelEvent.deltaY * 0.0015);
    if (explainerState.isTwoDimensional) {
      cameraRig.orthographicZoom = Math.max(0.3, Math.min(6, cameraRig.orthographicZoom / zoomFactor));
    } else {
      cameraRig.distance = Math.max(2, Math.min(80, cameraRig.distance * zoomFactor));
    }
  }, { passive: false });

  // ─── Applying actions ───────────────────────────────────────────────────

  function applyAction(action, isInstant) {
    if (!action || typeof action !== 'object') return;
    const actionName = String(action.do || '').toLowerCase();
    const targetIds = asArray(action.targets ?? action.target).map(String);
    const targetRecords = targetIds
      .map((targetId) => explainerState.objectRecordsById.get(targetId))
      .filter(Boolean);

    switch (actionName) {
      case 'show':
        targetRecords.forEach((objectRecord) => { objectRecord.isShown = true; });
        break;
      case 'hide':
        targetRecords.forEach((objectRecord) => { objectRecord.isShown = false; });
        break;
      case 'focus':
        explainerState.focusedObjectIds = new Set(targetIds);
        targetRecords.forEach((objectRecord) => { objectRecord.isShown = true; });
        break;
      case 'unfocus':
        explainerState.focusedObjectIds = null;
        break;
      case 'highlight':
        targetRecords.forEach((objectRecord) => {
          objectRecord.highlightColor = new THREE.Color(action.color || accentColor);
          if (action.glow && !objectRecord.highlightLight && !explainerState.isTwoDimensional) {
            objectRecord.highlightLight = new THREE.PointLight(objectRecord.highlightColor, 0, 8, 2);
            objectRecord.highlightLight.position.copy(resolvePoint(objectRecord.id));
            threeScene.add(objectRecord.highlightLight);
          }
        });
        break;
      case 'unhighlight':
        (targetRecords.length ? targetRecords : [...explainerState.objectRecordsById.values()]).forEach(clearHighlight);
        break;
      case 'cutaway':
        targetRecords.forEach((objectRecord) => {
          objectRecord.baseOpacity = action.opacity === undefined ? 0.16 : Number(action.opacity);
        });
        break;
      case 'color':
        targetRecords.forEach((objectRecord) => {
          if (action.color) objectRecord.currentBaseColor.set(action.color);
          if (action.color && objectRecord.material) objectRecord.material.color.set(action.color);
        });
        break;
      case 'label':
        if (action.position) {
          showLabel('position-' + JSON.stringify(action.position), action.text || '', null, vectorFrom(action.position, new THREE.Vector3()), null, action.math);
        } else {
          targetIds.forEach((targetId) => {
            showLabel(targetId, action.text || targetId, targetId, null, action.offset ? vectorFrom(action.offset, new THREE.Vector3()) : null, action.math);
          });
        }
        break;
      case 'unlabel':
        (targetIds.length ? targetIds : [...explainerState.labelRecordsByKey.keys()]).forEach(hideLabel);
        break;
      case 'arrow':
        addArrowEffect(action, isInstant);
        break;
      case 'flow':
        addFlowEffect(action);
        break;
      case 'plume':
        addPlumeEffect(action);
        break;
      case 'spin':
        targetRecords.forEach((objectRecord) => {
          objectRecord.spinAxis = String(action.axis || 'y').toLowerCase();
          objectRecord.spinTurnsPerSecond = Number(action.speed) || 1;
        });
        break;
      case 'stopspin':
        targetRecords.forEach((objectRecord) => { objectRecord.spinTurnsPerSecond = 0; });
        break;
      case 'draw':
        targetRecords.forEach((objectRecord) => {
          objectRecord.isShown = true;
          objectRecord.drawTargetProgress = 1;
          objectRecord.drawSecondsTotal = Number(action.seconds) || 1.5;
          if (isInstant) objectRecord.drawProgress = 1;
        });
        break;
      case 'move':
        targetRecords.forEach((objectRecord) => {
          const startPosition = objectRecord.mesh.position.clone();
          const endPosition = action.to
            ? vectorFrom(action.to, startPosition)
            : startPosition.clone().add(vectorFrom(action.by, new THREE.Vector3()));
          if (isInstant) {
            objectRecord.mesh.position.copy(endPosition);
            objectRecord.moveTween = null;
          } else {
            objectRecord.moveTween = { startPosition, endPosition, elapsedSeconds: 0, durationSeconds: Number(action.seconds) || 1.2 };
          }
        });
        break;
      case 'revolve':
        targetRecords.forEach((objectRecord) => {
          objectRecord.revolveCenter = vectorFrom(action.center, new THREE.Vector3());
          objectRecord.revolveAxis = String(action.axis || (explainerState.isTwoDimensional ? 'z' : 'y')).toLowerCase();
          objectRecord.revolveTurnsPerSecond = Number(action.speed) || 0.25;
        });
        break;
      case 'stoprevolve':
        targetRecords.forEach((objectRecord) => { objectRecord.revolveTurnsPerSecond = 0; });
        break;
      case 'add':
        asArray(action.objects ?? action.object).forEach((objectDescription) => {
          if (objectDescription && typeof objectDescription === 'object') buildSceneObject(objectDescription, true);
        });
        applyVariableBindings();
        break;
      case 'update':
        targetRecords.filter((objectRecord) => objectRecord.cardElement).forEach((objectRecord) => {
          for (const contentField of ['title', 'text', 'math']) {
            if (action[contentField] !== undefined) objectRecord.cardContent[contentField] = action[contentField] || undefined;
          }
          renderCardContent(objectRecord);
          if (!isInstant) {
            // Restart the change animation (removing and re-adding the class).
            objectRecord.cardElement.classList.remove('is-updating');
            void objectRecord.cardElement.offsetWidth;
            objectRecord.cardElement.classList.add('is-updating');
          }
        });
        break;
      case 'slider':
        showSlider(action);
        applyVariableBindings();
        break;
      case 'hidesliders':
        hideSliders();
        break;
      case 'camera':
        moveCamera(action, isInstant);
        break;
      case 'orbit':
        cameraRig.autoRotate = action.enabled !== false;
        break;
      case 'cleareffects':
        removeAllEffects();
        break;
      default:
        // Unknown actions are skipped so one typo doesn't break the scene.
        break;
    }
    refreshObjectTargetOpacities();
  }

  function clearHighlight(objectRecord) {
    objectRecord.highlightColor = null;
    if (objectRecord.highlightLight) {
      threeScene.remove(objectRecord.highlightLight);
      objectRecord.highlightLight.dispose();
      objectRecord.highlightLight = null;
    }
  }

  /** Back to how the scene looked before step 1, with nothing animating. */
  function resetSceneToInitialState() {
    explainerState.pendingDelayedActions = [];
    removeAllEffects();
    removeAllLabels();
    hideSliders();
    resetVariables();
    explainerState.focusedObjectIds = null;
    for (const objectRecord of [...explainerState.objectRecordsById.values()]) {
      if (objectRecord.isAddedByStep) {
        disposeSceneObject(objectRecord);
        continue;
      }
      clearHighlight(objectRecord);
      objectRecord.isShown = !objectRecord.description.hidden;
      objectRecord.baseOpacity = objectRecord.initialBaseOpacity;
      objectRecord.currentBaseColor.copy(objectRecord.initialColor);
      if (objectRecord.material) objectRecord.material.color.copy(objectRecord.initialColor);
      objectRecord.mesh.position.copy(objectRecord.initialPosition);
      objectRecord.mesh.rotation.copy(objectRecord.initialRotation);
      objectRecord.spinTurnsPerSecond = 0;
      objectRecord.revolveTurnsPerSecond = 0;
      objectRecord.moveTween = null;
      objectRecord.drawProgress = objectRecord.initialDrawProgress;
      objectRecord.drawTargetProgress = objectRecord.initialDrawProgress;
      if (objectRecord.cardElement) {
        objectRecord.cardContent = initialCardContent(objectRecord.description);
        renderCardContent(objectRecord);
      }
    }
    applyVariableBindings();
    for (const objectRecord of explainerState.objectRecordsById.values()) {
      objectRecord.currentOpacity = objectRecord.targetOpacity;
    }
    applyInitialCamera(true);
  }

  function applyInitialCamera(isInstant) {
    const sceneCamera = (explainerState.sceneDescription && explainerState.sceneDescription.camera) || {};
    cameraRig.autoRotate = sceneCamera.autoRotate !== false;
    if (sceneCamera.fit !== undefined || !sceneCamera.position) {
      cameraRig.azimuthInRadians = 0.8;
      cameraRig.polarInRadians = 1.15;
      moveCamera({ fit: sceneCamera.fit === undefined ? true : sceneCamera.fit, angle: sceneCamera.angle }, isInstant);
      return;
    }
    moveCamera({
      position: sceneCamera.position || (explainerState.isTwoDimensional ? [0, 0, 50] : [10, 7, 10]),
      target: sceneCamera.target || [0, 0, 0],
      zoom: 1,
    }, isInstant);
  }

  // ─── Steps and playback ─────────────────────────────────────────────────

  function estimatedStepSeconds(step) {
    if (step.seconds) return Math.max(2, Number(step.seconds));
    const wordCount = String(step.narration || '').split(/\s+/).filter(Boolean).length;
    // Leave time for the step's last delayed action to play out.
    const lastDelayedActionSeconds = Math.max(0, ...asArray(step.actions).map((action) =>
      (Number(action && action.delay) || 0) + (Number(action && action.seconds) || 0)));
    // About 2.6 spoken words per second, plus a beat to look at the visual.
    return Math.max(3.5, Math.min(20, Math.max(wordCount / 2.6, lastDelayedActionSeconds) + 1.5));
  }

  /** Actions with "delay" wait (scene time, paused with playback) before running. */
  function applyOrDelayAction(action) {
    const delaySeconds = Math.min(30, Number(action && action.delay) || 0);
    if (delaySeconds > 0) explainerState.pendingDelayedActions.push({ action, remainingSeconds: delaySeconds });
    else applyAction(action, false);
  }

  /** Runs the actions still waiting, right away (moving on or finishing). */
  function finishDelayedActionsNow() {
    const waitingActions = explainerState.pendingDelayedActions;
    explainerState.pendingDelayedActions = [];
    waitingActions.forEach((waitingAction) => applyAction(waitingAction.action, true));
  }

  function advanceDelayedActions(deltaSeconds) {
    if (!explainerState.pendingDelayedActions.length || !explainerState.isPlaying) return;
    const dueActions = [];
    explainerState.pendingDelayedActions = explainerState.pendingDelayedActions.filter((waitingAction) => {
      waitingAction.remainingSeconds -= deltaSeconds;
      if (waitingAction.remainingSeconds <= 0) { dueActions.push(waitingAction.action); return false; }
      return true;
    });
    dueActions.forEach((dueAction) => applyAction(dueAction, false));
  }

  function goToStep(requestedStepIndex) {
    const steps = explainerState.steps;
    if (!steps.length) return;
    const stepIndex = Math.max(0, Math.min(steps.length - 1, requestedStepIndex));
    const isNextStepInOrder = stepIndex === explainerState.currentStepIndex + 1;

    // Going back or jumping ahead rebuilds the state of every earlier step
    // instantly, so each step always looks the same however you got there.
    if (isNextStepInOrder) {
      finishDelayedActionsNow();
    } else {
      resetSceneToInitialState();
      for (let earlierStepIndex = 0; earlierStepIndex < stepIndex; earlierStepIndex++) {
        asArray(steps[earlierStepIndex].actions).forEach((action) => applyAction(action, true));
      }
      for (const objectRecord of explainerState.objectRecordsById.values()) {
        objectRecord.currentOpacity = objectRecord.targetOpacity;
      }
    }

    explainerState.currentStepIndex = stepIndex;
    asArray(steps[stepIndex].actions).forEach(applyOrDelayAction);
    showCaption(steps[stepIndex].narration || '');
    refreshStepControls();
    postToNative({ type: 'stepStarted', index: stepIndex, narration: steps[stepIndex].narration || '' });
    scheduleAutoAdvance();
  }

  function scheduleAutoAdvance() {
    clearTimeout(explainerState.stepAdvanceTimer);
    if (!explainerState.autoAdvance || !explainerState.isPlaying) return;
    const currentStep = explainerState.steps[explainerState.currentStepIndex];
    if (!currentStep) return;
    explainerState.stepAdvanceTimer = setTimeout(advanceToNextStep, estimatedStepSeconds(currentStep) * 1000);
  }

  function advanceToNextStep() {
    const nextStepIndex = explainerState.currentStepIndex + 1;
    if (nextStepIndex < explainerState.steps.length) {
      goToStep(nextStepIndex);
    } else if (explainerState.stepsStillStreaming) {
      // The next step hasn't arrived yet; appendSteps continues playback.
      explainerState.isWaitingForNextStep = true;
    } else {
      finishDelayedActionsNow();
      explainerState.isPlaying = false;
      refreshStepControls();
      postToNative({ type: 'finished' });
      offerQuizAtEnd();
    }
  }

  function showCaption(captionText) {
    captionElement.classList.add('is-changing');
    setTimeout(() => {
      captionElement.textContent = captionText;
      captionElement.classList.remove('is-changing');
    }, 180);
  }

  function refreshStepControls() {
    const stepCount = explainerState.steps.length;
    const currentStepIndex = explainerState.currentStepIndex;
    stepCounterElement.textContent = stepCount
      ? 'Step ' + (currentStepIndex + 1) + ' of ' + stepCount + (explainerState.stepsStillStreaming ? '+' : '')
      : '';
    previousButton.disabled = currentStepIndex <= 0;
    nextButton.disabled = currentStepIndex >= stepCount - 1;
    const isAtEnd = currentStepIndex >= stepCount - 1 && !explainerState.stepsStillStreaming && !explainerState.isPlaying;
    playPauseButton.textContent = isAtEnd ? '↺' : (explainerState.isPlaying ? '❚❚' : '▶');

    stepDotsElement.innerHTML = '';
    for (let stepIndex = 0; stepIndex < stepCount; stepIndex++) {
      const stepDot = document.createElement('button');
      stepDot.className = 'step-dot' + (stepIndex === currentStepIndex ? ' is-current' : stepIndex < currentStepIndex ? ' is-done' : '');
      stepDot.title = 'Step ' + (stepIndex + 1);
      stepDot.addEventListener('click', () => goToStep(stepIndex));
      stepDotsElement.appendChild(stepDot);
    }
  }

  function setPlaying(shouldPlay) {
    explainerState.isPlaying = shouldPlay;
    refreshStepControls();
    if (explainerState.autoAdvance) {
      if (shouldPlay) scheduleAutoAdvance();
      else clearTimeout(explainerState.stepAdvanceTimer);
    }
    postToNative({ type: 'playPauseRequested', isPlaying: shouldPlay });
  }

  playPauseButton.addEventListener('click', () => {
    const stepCount = explainerState.steps.length;
    const isAtEnd = explainerState.currentStepIndex >= stepCount - 1 && !explainerState.stepsStillStreaming && !explainerState.isPlaying;
    if (isAtEnd) {
      explainerState.isPlaying = true;
      goToStep(0);
      return;
    }
    setPlaying(!explainerState.isPlaying);
  });
  previousButton.addEventListener('click', () => goToStep(explainerState.currentStepIndex - 1));
  nextButton.addEventListener('click', () => goToStep(explainerState.currentStepIndex + 1));
  restartButton.addEventListener('click', () => {
    explainerState.isPlaying = true;
    goToStep(0);
  });
  closeButton.addEventListener('click', () => postToNative({ type: 'close' }));

  window.addEventListener('keydown', (keyEvent) => {
    // Arrow keys on a focused slider move the slider, not the steps.
    if (keyEvent.target && keyEvent.target.tagName === 'INPUT' && keyEvent.key !== 'Escape') return;
    if (keyEvent.key === 'Escape') postToNative({ type: 'close' });
    else if (keyEvent.key === ' ') { keyEvent.preventDefault(); playPauseButton.click(); }
    else if (keyEvent.key === 'ArrowRight') nextButton.click();
    else if (keyEvent.key === 'ArrowLeft') previousButton.click();
  });

  // ─── Quiz ───────────────────────────────────────────────────────────────

  const quizButton = document.getElementById('quiz-button');
  const quizPanel = document.getElementById('quiz-panel');
  const quizContentElement = document.getElementById('quiz-content');
  const libraryButton = document.getElementById('library-button');
  const libraryPanel = document.getElementById('library-panel');
  const libraryContentElement = document.getElementById('library-content');

  /** Questions look like { question, choices: [...], answerIndex, explanation }. */
  function setQuiz(quizQuestions) {
    explainerState.quizQuestions = asArray(quizQuestions).filter((quizQuestion) =>
      quizQuestion && quizQuestion.question && Array.isArray(quizQuestion.choices) && quizQuestion.choices.length >= 2
    );
    quizButton.hidden = explainerState.quizQuestions.length === 0;
  }

  /** At the end: open the quiz, unless sliders are out (the user is still
      playing with them), then the Quiz button glows instead. */
  function offerQuizAtEnd() {
    if (!sliderPanelElement.hidden) {
      quizButton.classList.add('is-attention');
      return;
    }
    showQuiz();
  }

  function showQuiz() {
    quizButton.classList.remove('is-attention');
    if (!explainerState.quizQuestions || !explainerState.quizQuestions.length) return;
    libraryPanel.hidden = true;
    quizPanel.hidden = false;
    explainerState.quizCorrectAnswerCount = 0;
    renderQuizQuestion(0);
  }

  function renderQuizQuestion(questionIndex) {
    const quizQuestions = explainerState.quizQuestions;
    quizContentElement.innerHTML = '';

    if (questionIndex >= quizQuestions.length) {
      const scoreElement = document.createElement('div');
      scoreElement.className = 'quiz-question';
      scoreElement.textContent = 'You got ' + explainerState.quizCorrectAnswerCount + ' of ' + quizQuestions.length + ' right.';
      const doneButton = document.createElement('button');
      doneButton.className = 'panel-primary-button';
      doneButton.textContent = 'Done';
      doneButton.addEventListener('click', () => { quizPanel.hidden = true; });
      quizContentElement.append(scoreElement, doneButton);
      postToNative({ type: 'quizFinished', correctCount: explainerState.quizCorrectAnswerCount, questionCount: quizQuestions.length });
      return;
    }

    const quizQuestion = quizQuestions[questionIndex];
    const progressElement = document.createElement('div');
    progressElement.className = 'quiz-progress';
    progressElement.textContent = 'Question ' + (questionIndex + 1) + ' of ' + quizQuestions.length;
    const questionElement = document.createElement('div');
    questionElement.className = 'quiz-question';
    questionElement.textContent = String(quizQuestion.question);
    quizContentElement.append(progressElement, questionElement);

    const correctChoiceIndex = Number(quizQuestion.answerIndex) || 0;
    const choiceButtons = quizQuestion.choices.map((choiceText, choiceIndex) => {
      const choiceButton = document.createElement('button');
      choiceButton.className = 'quiz-choice';
      choiceButton.textContent = String(choiceText);
      choiceButton.addEventListener('click', () => {
        const isCorrect = choiceIndex === correctChoiceIndex;
        if (isCorrect) explainerState.quizCorrectAnswerCount += 1;
        choiceButtons.forEach((otherButton, otherIndex) => {
          otherButton.disabled = true;
          if (otherIndex === correctChoiceIndex) otherButton.classList.add('is-correct');
        });
        if (!isCorrect) choiceButton.classList.add('is-wrong');

        const feedbackElement = document.createElement('div');
        feedbackElement.className = 'quiz-feedback';
        feedbackElement.textContent = (isCorrect ? 'Right! ' : 'Not quite. ') + String(quizQuestion.explanation || '');
        const nextButton = document.createElement('button');
        nextButton.className = 'panel-primary-button';
        nextButton.textContent = questionIndex + 1 < quizQuestions.length ? 'Next question' : 'See score';
        nextButton.addEventListener('click', () => renderQuizQuestion(questionIndex + 1));
        quizContentElement.append(feedbackElement, nextButton);
      });
      quizContentElement.appendChild(choiceButton);
      return choiceButton;
    });
  }

  quizButton.addEventListener('click', showQuiz);
  document.getElementById('quiz-close-button').addEventListener('click', () => { quizPanel.hidden = true; });

  // ─── Library ────────────────────────────────────────────────────────────

  /** Entries look like { id, title, detail }. */
  function showLibrary(libraryEntries) {
    quizPanel.hidden = true;
    document.getElementById('concept-map-panel').hidden = true;
    libraryPanel.hidden = false;
    libraryContentElement.innerHTML = '';
    const entries = asArray(libraryEntries);
    if (!entries.length) {
      const emptyElement = document.createElement('div');
      emptyElement.className = 'library-empty';
      emptyElement.textContent = 'No saved explanations yet. Ask heySona to explain how something works, and it will be saved here to replay anytime.';
      libraryContentElement.appendChild(emptyElement);
      return;
    }
    entries.forEach((libraryEntry) => {
      const entryElement = document.createElement('div');
      entryElement.className = 'library-entry';
      const textElement = document.createElement('div');
      textElement.className = 'library-entry-text';
      const titleElement = document.createElement('div');
      titleElement.className = 'library-entry-title';
      titleElement.textContent = String(libraryEntry.title || 'Untitled');
      const detailElement = document.createElement('div');
      detailElement.className = 'library-entry-detail';
      detailElement.textContent = String(libraryEntry.detail || '');
      textElement.append(titleElement, detailElement);

      const playButton = document.createElement('button');
      playButton.className = 'library-entry-button is-play';
      playButton.textContent = 'Play';
      playButton.addEventListener('click', () => {
        libraryPanel.hidden = true;
        postToNative({ type: 'libraryEntrySelected', id: String(libraryEntry.id) });
      });
      const deleteButton = document.createElement('button');
      deleteButton.className = 'library-entry-button';
      deleteButton.textContent = 'Delete';
      deleteButton.addEventListener('click', () => {
        entryElement.remove();
        postToNative({ type: 'libraryEntryDeleted', id: String(libraryEntry.id) });
        if (!libraryContentElement.querySelector('.library-entry')) showLibrary([]);
      });
      entryElement.append(textElement, playButton, deleteButton);
      libraryContentElement.appendChild(entryElement);
    });
  }

  libraryButton.addEventListener('click', () => postToNative({ type: 'libraryRequested' }));
  document.getElementById('library-close-button').addEventListener('click', () => { libraryPanel.hidden = true; });

  // ─── Concept map ────────────────────────────────────────────────────────

  const conceptMapPanel = document.getElementById('concept-map-panel');
  const conceptMapContentElement = document.getElementById('concept-map-content');

  /**
   * Graph: { nodes: [{ id, label, kind: "topic" | "related", explanationId? }],
   *          links: [{ from, to }] }. Topic nodes replay their explanation.
   * Laid out with a small force simulation, then drawn as SVG.
   */
  function showConceptMap(conceptGraph) {
    quizPanel.hidden = true;
    libraryPanel.hidden = true;
    conceptMapPanel.hidden = false;
    conceptMapContentElement.innerHTML = '';

    const graphNodes = asArray(conceptGraph && conceptGraph.nodes).map((graphNode) => ({ ...graphNode }));
    const graphLinks = asArray(conceptGraph && conceptGraph.links).filter((graphLink) =>
      graphNodes.some((graphNode) => graphNode.id === graphLink.from) && graphNodes.some((graphNode) => graphNode.id === graphLink.to)
    );
    if (!graphNodes.length) {
      const emptyElement = document.createElement('div');
      emptyElement.className = 'library-empty';
      emptyElement.textContent = 'Your map is empty. Ask heySona to explain a concept, and the ideas it covers will show up here, linked to everything else you learn.';
      conceptMapContentElement.appendChild(emptyElement);
      return;
    }

    const mapWidth = Math.max(300, conceptMapContentElement.clientWidth || 700);
    const mapHeight = Math.max(240, conceptMapContentElement.clientHeight || 440);
    const nodesById = new Map(graphNodes.map((graphNode) => [graphNode.id, graphNode]));

    // Start nodes on a circle (topics) and near their topic (related ideas).
    graphNodes.forEach((graphNode, nodeIndex) => {
      const startAngle = (nodeIndex / graphNodes.length) * Math.PI * 2;
      const startRadius = graphNode.kind === 'topic' ? Math.min(mapWidth, mapHeight) * 0.25 : Math.min(mapWidth, mapHeight) * 0.38;
      graphNode.x = mapWidth / 2 + Math.cos(startAngle) * startRadius;
      graphNode.y = mapHeight / 2 + Math.sin(startAngle) * startRadius;
      graphNode.velocityX = 0;
      graphNode.velocityY = 0;
    });

    // Force simulation: nodes repel, links pull together, everything drifts
    // toward the center. A fixed number of rounds keeps it deterministic.
    for (let simulationRound = 0; simulationRound < 320; simulationRound++) {
      const coolingFactor = 1 - simulationRound / 320;
      for (let firstIndex = 0; firstIndex < graphNodes.length; firstIndex++) {
        for (let secondIndex = firstIndex + 1; secondIndex < graphNodes.length; secondIndex++) {
          const firstNode = graphNodes[firstIndex];
          const secondNode = graphNodes[secondIndex];
          let deltaX = secondNode.x - firstNode.x;
          let deltaY = secondNode.y - firstNode.y;
          const distanceSquared = Math.max(80, deltaX * deltaX + deltaY * deltaY);
          const repulsion = 5200 / distanceSquared;
          const distance = Math.sqrt(distanceSquared);
          deltaX /= distance; deltaY /= distance;
          firstNode.velocityX -= deltaX * repulsion; firstNode.velocityY -= deltaY * repulsion;
          secondNode.velocityX += deltaX * repulsion; secondNode.velocityY += deltaY * repulsion;
        }
      }
      graphLinks.forEach((graphLink) => {
        const fromNode = nodesById.get(graphLink.from);
        const toNode = nodesById.get(graphLink.to);
        const deltaX = toNode.x - fromNode.x;
        const deltaY = toNode.y - fromNode.y;
        const distance = Math.max(1, Math.hypot(deltaX, deltaY));
        const pull = (distance - 95) * 0.012;
        fromNode.velocityX += deltaX / distance * pull; fromNode.velocityY += deltaY / distance * pull;
        toNode.velocityX -= deltaX / distance * pull; toNode.velocityY -= deltaY / distance * pull;
      });
      graphNodes.forEach((graphNode) => {
        graphNode.velocityX += (mapWidth / 2 - graphNode.x) * 0.004;
        graphNode.velocityY += (mapHeight / 2 - graphNode.y) * 0.004;
        graphNode.x += graphNode.velocityX * coolingFactor;
        graphNode.y += graphNode.velocityY * coolingFactor;
        graphNode.velocityX *= 0.6; graphNode.velocityY *= 0.6;
        graphNode.x = Math.max(70, Math.min(mapWidth - 70, graphNode.x));
        graphNode.y = Math.max(24, Math.min(mapHeight - 40, graphNode.y));
      });
    }

    const svgNamespace = 'http://www.w3.org/2000/svg';
    const mapSvg = document.createElementNS(svgNamespace, 'svg');
    mapSvg.setAttribute('viewBox', '0 0 ' + mapWidth + ' ' + mapHeight);

    graphLinks.forEach((graphLink) => {
      const fromNode = nodesById.get(graphLink.from);
      const toNode = nodesById.get(graphLink.to);
      const linkLine = document.createElementNS(svgNamespace, 'line');
      linkLine.setAttribute('x1', fromNode.x); linkLine.setAttribute('y1', fromNode.y);
      linkLine.setAttribute('x2', toNode.x); linkLine.setAttribute('y2', toNode.y);
      linkLine.setAttribute('stroke', fromNode.kind === 'topic' && toNode.kind === 'topic' ? 'rgba(51,128,255,0.7)' : 'rgba(107,115,111,0.55)');
      linkLine.setAttribute('stroke-width', fromNode.kind === 'topic' && toNode.kind === 'topic' ? '2' : '1.2');
      mapSvg.appendChild(linkLine);
    });

    graphNodes.forEach((graphNode) => {
      const isTopic = graphNode.kind === 'topic';
      const nodeGroup = document.createElementNS(svgNamespace, 'g');
      if (isTopic && graphNode.explanationId) {
        nodeGroup.setAttribute('class', 'concept-node-topic');
        nodeGroup.addEventListener('click', () => {
          conceptMapPanel.hidden = true;
          postToNative({ type: 'libraryEntrySelected', id: String(graphNode.explanationId) });
        });
        const tooltip = document.createElementNS(svgNamespace, 'title');
        tooltip.textContent = 'Replay: ' + graphNode.label;
        nodeGroup.appendChild(tooltip);
      }
      const nodeCircle = document.createElementNS(svgNamespace, 'circle');
      nodeCircle.setAttribute('cx', graphNode.x); nodeCircle.setAttribute('cy', graphNode.y);
      nodeCircle.setAttribute('r', isTopic ? 9 : 5);
      nodeCircle.setAttribute('fill', isTopic ? '#3380ff' : '#6b736f');
      const nodeLabel = document.createElementNS(svgNamespace, 'text');
      nodeLabel.setAttribute('x', graphNode.x); nodeLabel.setAttribute('y', graphNode.y + (isTopic ? 24 : 18));
      nodeLabel.setAttribute('text-anchor', 'middle');
      nodeLabel.setAttribute('fill', isTopic ? '#eceeed' : '#adb5b2');
      nodeLabel.setAttribute('font-size', isTopic ? '12.5' : '11');
      nodeLabel.setAttribute('font-weight', isTopic ? '600' : '400');
      nodeLabel.setAttribute('font-family', '-apple-system, sans-serif');
      // A dark outline behind the text keeps labels readable over link lines.
      nodeLabel.setAttribute('stroke', '#1a1c1b');
      nodeLabel.setAttribute('stroke-width', '4');
      nodeLabel.setAttribute('stroke-linejoin', 'round');
      nodeLabel.setAttribute('paint-order', 'stroke');
      nodeLabel.textContent = String(graphNode.label);
      nodeGroup.append(nodeCircle, nodeLabel);
      mapSvg.appendChild(nodeGroup);
    });

    conceptMapContentElement.appendChild(mapSvg);
  }

  document.getElementById('concept-map-button').addEventListener('click', () => postToNative({ type: 'conceptMapRequested' }));
  document.getElementById('concept-map-close-button').addEventListener('click', () => { conceptMapPanel.hidden = true; });

  // ─── Render loop ────────────────────────────────────────────────────────

  /** Slides (move) and orbits (revolve) objects each frame. */
  function updateObjectMotion(objectRecord, deltaSeconds) {
    const moveTween = objectRecord.moveTween;
    if (moveTween) {
      moveTween.elapsedSeconds += deltaSeconds;
      const easedProgress = easeInOutCubic(Math.min(1, moveTween.elapsedSeconds / moveTween.durationSeconds));
      objectRecord.mesh.position.lerpVectors(moveTween.startPosition, moveTween.endPosition, easedProgress);
      if (easedProgress >= 1) objectRecord.moveTween = null;
    }
    if (objectRecord.revolveTurnsPerSecond && objectRecord.revolveCenter) {
      const revolveAngle = deltaSeconds * objectRecord.revolveTurnsPerSecond * Math.PI * 2;
      const revolveAxisVector = objectRecord.revolveAxis === 'x'
        ? new THREE.Vector3(1, 0, 0)
        : objectRecord.revolveAxis === 'z' ? new THREE.Vector3(0, 0, 1) : new THREE.Vector3(0, 1, 0);
      objectRecord.mesh.position
        .sub(objectRecord.revolveCenter)
        .applyAxisAngle(revolveAxisVector, revolveAngle)
        .add(objectRecord.revolveCenter);
    }
  }

  const projectedCardPosition = new THREE.Vector3();

  function positionCard(objectRecord) {
    const cardElement = objectRecord.cardElement;
    cardElement.style.opacity = String(objectRecord.currentOpacity);
    cardElement.style.display = objectRecord.currentOpacity > 0.01 ? 'block' : 'none';
    const isFocused = explainerState.focusedObjectIds && explainerState.focusedObjectIds.has(objectRecord.id);
    cardElement.classList.toggle('is-highlighted', Boolean(objectRecord.highlightColor || isFocused));
    projectedCardPosition.copy(objectRecord.mesh.getWorldPosition(new THREE.Vector3())).project(activeCamera);
    // Centered on its anchor, but kept fully inside the stage (wide equations).
    const stageWidth = stageElement.clientWidth;
    const stageHeight = stageElement.clientHeight;
    const cardHalfWidth = Math.min(stageWidth / 2, cardElement.offsetWidth / 2);
    const cardHalfHeight = Math.min(stageHeight / 2, cardElement.offsetHeight / 2);
    const cardCenterX = (projectedCardPosition.x + 1) / 2 * stageWidth;
    const cardCenterY = (1 - projectedCardPosition.y) / 2 * stageHeight;
    cardElement.style.left = Math.max(cardHalfWidth + 6, Math.min(stageWidth - cardHalfWidth - 6, cardCenterX)) + 'px';
    cardElement.style.top = Math.max(cardHalfHeight + 6, Math.min(stageHeight - cardHalfHeight - 6, cardCenterY)) + 'px';
  }

  function resizeRendererToStage() {
    const stageWidth = Math.max(1, stageElement.clientWidth);
    const stageHeight = Math.max(1, stageElement.clientHeight);
    renderer.setSize(stageWidth, stageHeight, false);
    perspectiveCamera.aspect = stageWidth / stageHeight;
    perspectiveCamera.updateProjectionMatrix();

    const viewWidth = Number(explainerState.sceneDescription?.view?.width) || 16;
    const viewHeight = viewWidth * stageHeight / stageWidth;
    orthographicCamera.left = -viewWidth / 2;
    orthographicCamera.right = viewWidth / 2;
    orthographicCamera.top = viewHeight / 2;
    orthographicCamera.bottom = -viewHeight / 2;
    orthographicCamera.updateProjectionMatrix();
  }
  new ResizeObserver(resizeRendererToStage).observe(stageElement);

  let previousFrameTime = performance.now();
  let elapsedSceneSeconds = 0;

  function renderFrame(frameTime) {
    const deltaSeconds = Math.min(0.05, (frameTime - previousFrameTime) / 1000);
    previousFrameTime = frameTime;
    advanceAndRender(deltaSeconds);
    requestAnimationFrame(renderFrame);
  }

  /** Moves every animation forward by `deltaSeconds` and draws one frame. */
  function advanceAndRender(deltaSeconds) {
    elapsedSceneSeconds += deltaSeconds;
    advanceDelayedActions(deltaSeconds);

    for (const objectRecord of explainerState.objectRecordsById.values()) {
      // Ease opacity toward its target for smooth show/hide/focus.
      objectRecord.currentOpacity += (objectRecord.targetOpacity - objectRecord.currentOpacity) * Math.min(1, deltaSeconds * 6);
      objectRecord.mesh.visible = objectRecord.currentOpacity > 0.01;
      updateObjectMotion(objectRecord, deltaSeconds);

      if (objectRecord.cardElement) {
        positionCard(objectRecord);
        continue;
      }

      objectRecord.material.opacity = objectRecord.currentOpacity;
      objectRecord.material.depthWrite = objectRecord.currentOpacity > 0.95;

      // Trace lines progressively when they're being drawn.
      if (objectRecord.drawProgress < objectRecord.drawTargetProgress) {
        objectRecord.drawProgress = Math.min(objectRecord.drawTargetProgress, objectRecord.drawProgress + deltaSeconds / objectRecord.drawSecondsTotal);
      }
      const indexCount = objectRecord.mesh.geometry.index ? objectRecord.mesh.geometry.index.count : Infinity;
      objectRecord.mesh.geometry.setDrawRange(0, objectRecord.drawProgress >= 1 ? Infinity : Math.floor(indexCount * objectRecord.drawProgress / 3) * 3);
      // Plot markers appear as the line is traced past them.
      const markerCount = objectRecord.plotMarkerMeshes.length;
      objectRecord.plotMarkerMeshes.forEach((markerMesh, markerIndex) => {
        markerMesh.visible = markerCount < 2 || markerIndex / (markerCount - 1) <= objectRecord.drawProgress + 0.001;
      });

      if (!objectRecord.material.emissive) {
        // Flat 2D materials have no glow, so highlights tint the color instead.
        if (objectRecord.highlightColor) {
          const pulse = 0.45 + Math.sin(elapsedSceneSeconds * 4) * 0.2;
          objectRecord.material.color.copy(objectRecord.currentBaseColor).lerp(objectRecord.highlightColor, pulse);
        } else {
          objectRecord.material.color.copy(objectRecord.currentBaseColor);
        }
      } else {
        const isFocused = explainerState.focusedObjectIds && explainerState.focusedObjectIds.has(objectRecord.id);
        if (objectRecord.highlightColor) {
          const pulse = 0.55 + Math.sin(elapsedSceneSeconds * 4) * 0.25;
          objectRecord.material.emissive.copy(objectRecord.highlightColor).multiplyScalar(pulse);
        } else if (isFocused) {
          // Neutral lift, so warm colors (copper, orange) don't turn purple.
          objectRecord.material.emissive.setRGB(0.07, 0.07, 0.07);
        } else {
          objectRecord.material.emissive.setRGB(0, 0, 0);
        }
      }
      if (objectRecord.highlightLight) {
        objectRecord.highlightLight.intensity = 30 + Math.sin(elapsedSceneSeconds * 4) * 10;
      }
      if (objectRecord.spinTurnsPerSecond) {
        objectRecord.mesh.rotation[objectRecord.spinAxis === 'x' ? 'x' : objectRecord.spinAxis === 'z' ? 'z' : 'y'] +=
          deltaSeconds * objectRecord.spinTurnsPerSecond * Math.PI * 2;
      }
    }

    for (const effect of explainerState.activeEffects) effect.update(deltaSeconds);

    updateCamera(deltaSeconds);
    renderer.render(threeScene, activeCamera);
    positionLabels();
  }
  requestAnimationFrame(renderFrame);

  // ─── Public API ─────────────────────────────────────────────────────────

  function loadScene(sceneDescription, options) {
    try {
      const loadOptions = options || {};
      clearTimeout(explainerState.stepAdvanceTimer);
      removeAllEffects();
      removeAllLabels();
      for (const objectRecord of [...explainerState.objectRecordsById.values()]) disposeSceneObject(objectRecord);
      explainerState.sceneObjectsGroup.clear();
      explainerState.objectRecordsById.clear();
      if (explainerState.floorGrid) {
        threeScene.remove(explainerState.floorGrid);
        explainerState.floorGrid = null;
      }

      explainerState.sceneDescription = sceneDescription || {};
      explainerState.isTwoDimensional = String(explainerState.sceneDescription.mode || '3d').toLowerCase() === '2d';
      activeCamera = explainerState.isTwoDimensional ? orthographicCamera : perspectiveCamera;
      explainerState.steps = asArray(explainerState.sceneDescription.steps).slice();
      explainerState.stepsStillStreaming = Boolean(loadOptions.stepsStillStreaming);
      explainerState.autoAdvance = loadOptions.autoAdvance !== false;
      explainerState.isPlaying = true;
      explainerState.currentStepIndex = -1;
      explainerState.pendingDelayedActions = [];
      hideSliders();
      resetVariables();

      sceneTitleElement.textContent = explainerState.sceneDescription.title || 'heySona';
      loadingMessageElement.style.display = 'none';
      quizPanel.hidden = true;
      libraryPanel.hidden = true;
      setQuiz(explainerState.sceneDescription.quiz);

      asArray(explainerState.sceneDescription.objects).forEach((objectDescription) => buildSceneObject(objectDescription, false));

      if (!explainerState.isTwoDimensional && explainerState.sceneDescription.floor !== false) {
        const floorGrid = new THREE.GridHelper(24, 24, 0x3380ff, 0x2a3346);
        floorGrid.material.transparent = true;
        floorGrid.material.opacity = 0.18;
        floorGrid.position.y = Number(explainerState.sceneDescription.floorY) || 0;
        threeScene.add(floorGrid);
        explainerState.floorGrid = floorGrid;
      }

      resizeRendererToStage();
      applyVariableBindings();
      applyInitialCamera(true);
      captionElement.textContent = '';
      refreshStepControls();
      if (explainerState.steps.length) goToStep(0);
    } catch (loadError) {
      postToNative({ type: 'error', message: 'Could not load scene: ' + loadError.message });
    }
  }

  function appendSteps(newSteps) {
    const wasWaitingForNextStep = explainerState.isWaitingForNextStep || explainerState.currentStepIndex < 0;
    explainerState.steps.push(...asArray(newSteps));
    explainerState.isWaitingForNextStep = false;
    refreshStepControls();
    if (wasWaitingForNextStep && explainerState.isPlaying && explainerState.autoAdvance) {
      goToStep(explainerState.currentStepIndex + 1);
    }
  }

  function finishSteps() {
    explainerState.stepsStillStreaming = false;
    refreshStepControls();
    if (explainerState.isWaitingForNextStep) advanceToNextStep();
  }

  window.heySonaExplainer = {
    loadScene,
    appendSteps,
    finishSteps,
    goToStep,
    play: () => setPlaying(true),
    pause: () => setPlaying(false),
    /** Voice-driven playback calls this after the last step's narration,
        so the play button turns into "replay". */
    markFinished() {
      finishDelayedActionsNow();
      explainerState.isPlaying = false;
      refreshStepControls();
      offerQuizAtEnd();
    },
    setQuiz,
    showQuiz,
    showLibrary,
    showConceptMap,
    /** A follow-up question is adding steps to this finished scene. */
    continueScene() {
      explainerState.stepsStillStreaming = true;
      explainerState.isPlaying = true;
      quizPanel.hidden = true;
      libraryPanel.hidden = true;
      refreshStepControls();
    },
    /** Shows a message in the stage while the scene is being prepared. */
    showStatus(statusText) {
      loadingMessageElement.textContent = String(statusText);
      loadingMessageElement.style.display = 'flex';
    },
    /** Test-only: runs the animation forward without waiting for the screen
        (an off-screen test window gets no animation frames). */
    advanceFramesForTesting(frameCount) {
      for (let frameIndex = 0; frameIndex < frameCount; frameIndex++) advanceAndRender(1 / 60);
    },
  };

  postToNative({ type: 'ready' });
})();
