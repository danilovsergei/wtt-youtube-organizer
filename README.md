# Description
 Wtt-youtube-organizer is an application which makes watching ping pong matches published to [Wtt](https://worldtabletennis.com/) [youtube channel](https://www.youtube.com/@WTTGlobal/videos) more fun.

[Wtt](https://worldtabletennis.com/) does great job by publishing videos from all tournaments to their [youtube channel](https://www.youtube.com/@WTTGlobal/videos)\
However there are several problems which make the matches less enjoyable:

* There are always newest matches listed first in the video feed. And wtt often publishes videos in chunks. Eg. QF and SF matches are published in the same time and SF match pops up first.\
Right after opening it does not make sense to watch QF anymore because results are known.

* There are constant spoilers like match interviews with winners which are coming at the same time as a match itself
* Youtube videos have a duration which immediately gives prediction what kind of match it is.\
Also during a watching a match video duration gives clear understanding will it be 3-2 or 3-1. Which is not fun as well.


Wtt-youtube-organizer solves all of these problems.
It reads the [wtt youtube channel](https://www.youtube.com/@WTTGlobal/videos) and generates a folder structure resembling tournaments\
It reads the [wtt youtube channel](https://www.youtube.com/@WTTGlobal/videos) and generates a folder structure resembling tournaments\
Generated links are simply the shell scripts which play the game using [yt-dlp](https://github.com/yt-dlp/yt-dlp) in [mpv](https://mpv.io/) video player

https://github.com/danilovsergei/wtt-youtube-organizer/assets/9714823/e1e506d6-87f8-47f8-9a52-d2f29f8ce862


# Features
* Browse through the tournaments and stages as a tree and open only what you need
* Video player opens a video without showing the duration. Watch it with no clue how long is the match
* Player memorizes watched position in the match. Re-open will open where you stopped
* `wtt-youtube-organizer` command supports filters. See the [use filters](#use-filters)(#use-filters)

# Requirements
* [yt-dlp](https://github.com/yt-dlp/yt-dlp)
* [mpv](https://mpv.io/) video player

# Installation
Tested only under linux

1. Download and go to the project root folder
2. Build by running `build.sh`
3. Optionally Put `systemd/youtube-filter.service` and `systemd/youtube-filter.timer` into the systemd user directory and edit them to specify absolute path to the wtt-youtube-organizer binary.\
That will allow to run `wtt-youtube-organizer` each 5 minutes to check new matches and update folder structure

# Usage
## Generate folder structure
Run `bin/wtt-youtube-organizer folder --saveWatchedTimeMpvScript=lua/mpv-customstart.lua` to generate folder structure.\
Command will create `wtt` folder in the user's home with last tournaments.\
By default last 200 matched parsed.

`--saveWatchedTimeMpvScript` arg is optional. Without it matches watched state will not be saved and opening a match will always start from the bebinning 

## View matches as list
Run `bin/wtt-youtube-organizer show` to view the matches as list in the console.\
There are numerous filters supported. Check with `wtt-youtube-organizer --help`

## Play match from youtube link
`wtt-youtube-organizer play <youtube_url>` is the command which incapsulates [yt-dlp](https://github.com/yt-dlp/yt-dlp) to stream the video from the link and [mpv](https://mpv.io/) to play it.

The even better command is
```
wtt-youtube-organizer play --videoUrl "https://www.youtube.com/watch?v=lNOR7_52siI" --saveWatchedTimeMpvScript "lua/mpv-customstart.lua"
```
It saves watched state and resumes it if the same video url opened\
It's the command generated sh scripts are using

## Use filters
Both `wtt-youtube-organizer show` and `wtt-youtube-organizer folder` suport filters.\
Run `wtt-youtube-organizer --help` to view all the options. Some useful:

* only man singles :`wtt-youtube-organizer folder --gender "MS"`
* only full matches: `wtt-youtube-organizer folder --full`
* specific tournament: `wtt-youtube-organizer folder --tour "Chongqing"`
