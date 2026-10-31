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
    pipes), rect (size [w,h]), circle (radius), ring (innerRadius, outerRadius).

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

  ─── JavaScript API (called from Swift) ──────────────────────────────────
    heySonaExplainer.loadScene(scene, { autoAdvance: true, stepsStillStreaming: false })
    heySonaExplainer.appendSteps([step, ...])      add steps while they stream in
    heySonaExplainer.finishSteps()                 no more steps will come
    heySonaExplainer.goToStep(index)
    heySonaExplainer.play() / .pause()
  Messages to Swift (window.webkit.messageHandlers.heySona):
    { type: "ready" } | { type: "stepStarted", index, narration } | { type: "finished" }
    { type: "close" } | { type: "playPauseRequested", isPlaying } | { type: "error", message }
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
    return boundingBox.getCenter(new THREE.Vector3());
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

  function buildSceneObject(objectDescription) {
    const shape = String(objectDescription.shape || 'box').toLowerCase();
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

    const mesh = new THREE.Mesh(makeGeometry(objectDescription), material);
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
    const objectRecord = {
      id: String(objectDescription.id || ('object-' + explainerState.objectRecordsById.size)),
      description: objectDescription,
      mesh,
      material,
      initialColor: new THREE.Color(objectDescription.color || '#8fa3c7'),
      initialRotation: mesh.rotation.clone(),
      initialBaseOpacity: baseOpacity,
      baseOpacity,
      isShown: isInitiallyShown,
      currentOpacity: isInitiallyShown ? baseOpacity : 0,
      targetOpacity: isInitiallyShown ? baseOpacity : 0,
      highlightColor: null,
      highlightLight: null,
      spinAxis: null,
      spinTurnsPerSecond: 0,
    };
    material.opacity = objectRecord.currentOpacity;
    mesh.visible = objectRecord.currentOpacity > 0.01;
    explainerState.sceneObjectsGroup.add(mesh);
    explainerState.objectRecordsById.set(objectRecord.id, objectRecord);
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

  function showLabel(labelKey, labelText, anchorObjectId, anchorPosition, offset) {
    let labelRecord = explainerState.labelRecordsByKey.get(labelKey);
    if (!labelRecord) {
      const labelElement = document.createElement('div');
      labelElement.className = 'scene-label';
      labelElement.innerHTML = '<div class="scene-label-text"></div><div class="scene-label-leader"></div><div class="scene-label-anchor"></div>';
      labelLayerElement.appendChild(labelElement);
      labelRecord = { element: labelElement };
      explainerState.labelRecordsByKey.set(labelKey, labelRecord);
    }
    labelRecord.element.querySelector('.scene-label-text').textContent = String(labelText);
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
      labelRecord.element.style.left = ((projectedLabelPosition.x + 1) / 2 * stageWidth) + 'px';
      labelRecord.element.style.top = ((1 - projectedLabelPosition.y) / 2 * stageHeight) + 'px';
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
          if (action.color) objectRecord.material.color.set(action.color);
        });
        break;
      case 'label':
        if (action.position) {
          showLabel('position-' + JSON.stringify(action.position), action.text || '', null, vectorFrom(action.position, new THREE.Vector3()), null);
        } else {
          targetIds.forEach((targetId) => {
            showLabel(targetId, action.text || targetId, targetId, null, action.offset ? vectorFrom(action.offset, new THREE.Vector3()) : null);
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
    removeAllEffects();
    removeAllLabels();
    explainerState.focusedObjectIds = null;
    for (const objectRecord of explainerState.objectRecordsById.values()) {
      clearHighlight(objectRecord);
      objectRecord.isShown = !objectRecord.description.hidden;
      objectRecord.baseOpacity = objectRecord.initialBaseOpacity;
      objectRecord.material.color.copy(objectRecord.initialColor);
      objectRecord.mesh.rotation.copy(objectRecord.initialRotation);
      objectRecord.spinTurnsPerSecond = 0;
    }
    refreshObjectTargetOpacities();
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
    // About 2.6 spoken words per second, plus a beat to look at the visual.
    return Math.max(3.5, Math.min(16, wordCount / 2.6 + 1.5));
  }

  function goToStep(requestedStepIndex) {
    const steps = explainerState.steps;
    if (!steps.length) return;
    const stepIndex = Math.max(0, Math.min(steps.length - 1, requestedStepIndex));
    const isNextStepInOrder = stepIndex === explainerState.currentStepIndex + 1;

    // Going back or jumping ahead rebuilds the state of every earlier step
    // instantly, so each step always looks the same however you got there.
    if (!isNextStepInOrder) {
      resetSceneToInitialState();
      for (let earlierStepIndex = 0; earlierStepIndex < stepIndex; earlierStepIndex++) {
        asArray(steps[earlierStepIndex].actions).forEach((action) => applyAction(action, true));
      }
      for (const objectRecord of explainerState.objectRecordsById.values()) {
        objectRecord.currentOpacity = objectRecord.targetOpacity;
      }
    }

    explainerState.currentStepIndex = stepIndex;
    asArray(steps[stepIndex].actions).forEach((action) => applyAction(action, false));
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
      explainerState.isPlaying = false;
      refreshStepControls();
      postToNative({ type: 'finished' });
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
    if (keyEvent.key === 'Escape') postToNative({ type: 'close' });
    else if (keyEvent.key === ' ') { keyEvent.preventDefault(); playPauseButton.click(); }
    else if (keyEvent.key === 'ArrowRight') nextButton.click();
    else if (keyEvent.key === 'ArrowLeft') previousButton.click();
  });

  // ─── Render loop ────────────────────────────────────────────────────────

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

    for (const objectRecord of explainerState.objectRecordsById.values()) {
      // Ease opacity toward its target for smooth show/hide/focus.
      objectRecord.currentOpacity += (objectRecord.targetOpacity - objectRecord.currentOpacity) * Math.min(1, deltaSeconds * 6);
      objectRecord.material.opacity = objectRecord.currentOpacity;
      objectRecord.material.depthWrite = objectRecord.currentOpacity > 0.95;
      objectRecord.mesh.visible = objectRecord.currentOpacity > 0.01;

      if (objectRecord.material.emissive) {
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
      for (const objectRecord of explainerState.objectRecordsById.values()) {
        clearHighlight(objectRecord);
        objectRecord.mesh.geometry.dispose();
        objectRecord.material.dispose();
      }
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

      sceneTitleElement.textContent = explainerState.sceneDescription.title || 'heySona';
      loadingMessageElement.style.display = 'none';

      asArray(explainerState.sceneDescription.objects).forEach(buildSceneObject);

      if (!explainerState.isTwoDimensional && explainerState.sceneDescription.floor !== false) {
        const floorGrid = new THREE.GridHelper(24, 24, 0x3380ff, 0x2a3346);
        floorGrid.material.transparent = true;
        floorGrid.material.opacity = 0.18;
        floorGrid.position.y = Number(explainerState.sceneDescription.floorY) || 0;
        threeScene.add(floorGrid);
        explainerState.floorGrid = floorGrid;
      }

      resizeRendererToStage();
      refreshObjectTargetOpacities();
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
    /** Test-only: runs the animation forward without waiting for the screen
        (an off-screen test window gets no animation frames). */
    advanceFramesForTesting(frameCount) {
      for (let frameIndex = 0; frameIndex < frameCount; frameIndex++) advanceAndRender(1 / 60);
    },
  };

  postToNative({ type: 'ready' });
})();
