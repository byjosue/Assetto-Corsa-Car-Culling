CAR CULLING 1.5.1
=================

Install
  1. Delete the old CarCulling folder from  assettocorsa\apps\lua\  and copy the new one in, so you end up with
     assettocorsa\apps\lua\CarCulling\CarCulling.lua  (manifest.ini changed too, so copy all three files).
  2. Restart the game (not just the session) and join an online server, or a race against bots. The app starts by itself
     with the game and keeps running with its window closed. To change the settings or see the counters, open "Car Culling" from the in-game
     app list.

What it does
  - Hide cars nobody is driving: the cars of free slots, parked in the pit lane, are not drawn.
    A car is drawn again as soon as a driver joins its slot or the car starts moving.
  - Only draw the nearest cars: optional, draws only the nearest N cars (measured from the camera)
    plus every car within the chosen distance. Your own car and the car you are watching are always drawn.
  - Against bots the nearest-cars option works the same way. Bots count as drivers, so "Hide cars nobody is driving"
    leaves them alone (it only hides the empty slots of an online server). Tune the distance and the number of cars there.
  - Only the 3D models are hidden. Physics, collisions and the network are not touched, so
    a hidden car can still be hit.

Only draw the nearest cars (all the settings are in the window)
  - Draw the nearest N cars, plus every car within a distance. Other cars are hidden.
  - Measure the distance: "Straight line" (as the crow flies, the default), or "Along the track" (the distance
    you would have to drive). Along the track, a car on the other side of a hairpin counts as far away even if it
    is close in a straight line, because you are much less likely to see it. A car less than 20 m away in a straight
    line is never hidden because of that.
  - "Straight line when off the track or in the pits" (on by default): along the track, the app switches to a
    straight line by itself while you have 3 or more wheels off the track, and for about 2 seconds after, and while
    you are in the pit lane. A straight line is also used when the camera is far from the car (replays, free
    camera) or the track gives no distance information. The window says which one is in use ("Distance: ...").
  - "Different limits in front of and behind me": the numbers and the distances can be set separately for the cars
    in front of and the cars behind the car you are watching (a car is in front when it is ahead of that car's nose,
    seen from above). A car has to be 5 m into the other half before it changes sides, so cars driving side by
    side do not pop in and out. This only applies with more than the chosen number of other cars (cars nobody
    drives are not counted); with fewer, the two normal sliders are used. With this option on, the window shows
    the normal sliders under "With N other cars or fewer:", and does not show them when N is 0 (they would do
    nothing then). With the option off, the sliders for the front and the back are not shown.
  - The window shows how many cars were hidden in front and behind.

How cars are hidden (choose in the window, the first one is the default)
  1. The car and every part of it: switches off the car and every mesh of it. This is the "Stronger hiding" of the
     earlier versions, now the normal way, because online switching off the car as a whole was not enough.
  2. The car as a whole only: the lightest way, but online the game switches the car on again before it is drawn,
     so the cars only flicker.
  3. Switch unoccupied cars off: unoccupied cars are switched off with ac.setCarActive; cars hidden for being far away
     use way 1. Try this if way 1 still leaves cars drawn or cars do not come back.

Getting the cars back
  - Untick "Active": every car is drawn again. Closing the window does NOT stop the app, only unticking "Active" does.
  - "Stop and draw every car" (bottom of the window): unticks "Active" and tries again for cars that did not come back.
  - If a car does not come back, press "Copy report" and send the text (paste it into the chat). The window also turns red
    when a car could not be put back completely.

What changed in 1.5.1
  The window only shows the sliders that do something: the front/back sliders only with the front/back option on,
  and the normal sliders (with a heading) only when they still apply.

What changed in 1.5
  Separate limits for the cars in front and behind, the "only with more than N cars" setting, distance along the
  track with the automatic switch to a straight line off the track and in the pits.
  This was tested against a simulated game only. Tell me if cars pop in more than before, and which settings you used
  (the "Copy report" text includes the distance mode, the front/back state and the hidden counts).

What changed in 1.4.1
  The app now also loads in offline sessions (races against bots); before, it switched itself off there.

What changed in 1.4
  Versions 1.1 to 1.3 had two problems: hiding the car as a whole did not work online (cars flickered), and hiding every
  part of the car worked but the cars never came back. In 1.4 the parts of a car are looked up once, before the car
  is hidden for the first time, together with which of them were visible. The same references are used to put them
  back (a new search made while the car is hidden may not find the hidden parts), each part gets its own state back,
  and the result is checked afterwards, with a second way of putting them back if the first does not work.
  The car as a whole is switched on again from the UI callback (the moment the "Car Culling Lab" buttons ran in)
  and kept on for about 30 frames.
  This was tested against a simulated game, not yet in the real game. The "Copy report" text tells me how many parts
  a car has, how many a new search finds while it is hidden, and whether they all came back.

Remove
  Delete the CarCulling folder. (Or untick "Active" in its window: every car is drawn again at once.)

graphics_adjustments_snippet.ini holds the built-in CSP options, with where to put them.
