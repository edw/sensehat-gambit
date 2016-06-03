(c-declare #<<c-declare-end

#define DEV_FB "/dev"
#define FB_DEV_NAME "fb"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <time.h>
#include <dirent.h>
#include <string.h>

#include <linux/fb.h>

#define SENSE_HAT_FB_FBIOGET_GAMMA 61696
#define SENSE_HAT_FB_FBIOSET_GAMMA 61697
#define SENSE_HAT_FB_FBIORESET_GAMMA 61698
#define SENSE_HAT_FB_GAMMA_DEFAULT 0
#define SENSE_HAT_FB_GAMMA_LOW 1
#define SENSE_HAT_FB_GAMMA_USER 2

struct fb_t {
	uint16_t pixel[8][8];
};

struct fb_t *fb;
int fbfd = -1;

static int is_framebuffer_device(const struct dirent *dir)
{
		return strncmp(FB_DEV_NAME, dir->d_name,
		       strlen(FB_DEV_NAME)-1) == 0;
}

static int open_fbdev(const char *dev_name)
{
	struct dirent **namelist;
	int i, ndev;
	int fd = -1;
	struct fb_fix_screeninfo fix_info;

	ndev = scandir(DEV_FB, &namelist, is_framebuffer_device, alphasort);
	if (ndev <= 0)
		return ndev;

	for (i = 0; i < ndev; i++)
	{
		char fname[64];
		char name[256];

		snprintf(fname, sizeof(fname),
			 "%s/%s", DEV_FB, namelist[i]->d_name);
		fd = open(fname, O_RDWR);
		if (fd < 0)
			continue;
		ioctl(fd, FBIOGET_FSCREENINFO, &fix_info);
		if (strcmp(dev_name, fix_info.id) == 0)
			break;
		close(fd);
		fd = -1;
	}
	for (i = 0; i < ndev; i++)
		free(namelist[i]);

	return fd;
}

extern int init_fb()
{
	fbfd = open_fbdev("RPi-Sense FB");
	if (fbfd <= 0) {
		printf("Error: cannot open framebuffer device.\n");
		return 0;
	}
	
	fb = mmap(0, 128, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
	if (!fb) {
		printf("Failed to mmap.\n");
		return 0;
	}

	return 1;
}

extern int shutdown_fb(void) {
  if (fb) {
    munmap(fb, 128);
    fb = NULL;
  }

  if (fbfd != -1) {
	close(fbfd);
	fbfd = -1;
  }
  return 1;
}

extern int plot_fb(int x, int y, uint16_t px) {
  fb->pixel[y][x] = px;
  return 1;
}

int set_lowlight_fb(int lowp) {
  int ret;
  ret = ioctl(fbfd, SENSE_HAT_FB_FBIORESET_GAMMA,
              lowp ? SENSE_HAT_FB_GAMMA_LOW :
              SENSE_HAT_FB_GAMMA_DEFAULT); 
  return ret != -1;
}

#define COMPONENT_RED 0
#define COMPONENT_GREEN 1
#define COMPONENT_BLUE 2

uint16_t px_component_mask(px, component) {
  uint16_t ret;
  switch(component) {
  case COMPONENT_RED:
    ret = 0x1f & (px >> 11);
    break;
  case COMPONENT_GREEN:
    ret = 0x3f & (px >> 5);
    break;
  case COMPONENT_BLUE:
    ret = 0x1f & px;
    break;
  default:
    ret = 0;
  }
  return ret;
}

uint16_t px_component_normalize(int px, int component) {
  uint16_t max = component != COMPONENT_GREEN ? 0x1f : 0x3f;
  int bits = (component != COMPONENT_BLUE ? 5 : 0) +
    (component == COMPONENT_RED ? 6 : 0);
  int max_px = (px > max) ? max : px;
  int min_px = (max_px < 0) ? 0 : max_px;
  return (uint16_t)min_px << bits;
}

uint16_t blit_op(int mode, uint16_t bot, uint16_t top) {
  int ret;
  switch(mode) {
  case 0:
    ret = top;
    break;
  case 1:
    if(top == 0)
      ret = bot;
    else
      ret = top;
    break;
  default:
    ret = bot;
  };
  return ret;
}

const int xo = 0, yo = 0, wf = 8, hf = 8;

int blit_fb(uint16_t *pxs, int w, int h, int x, int y, int mode) {
  int y1, x1;

  if (x == 0 && w == wf && y == 0 && h == hf && mode == 0) {
    memcpy(fb->pixel, pxs, w * h * sizeof(fb->pixel[0]));
    return 1;
  }

  for (y1 = 0; y1 < h; y1++) {
    int fby = y1 + yo + y;

    if (fby < 0) continue;
    if (fby >= wf) break;
    
    for (x1 = 0; x1 < w; x1++) {
      int fbx = x1 + xo + x;

      if (fbx < 0) continue;
      if (fbx >= hf) break;

      int i = (fby * wf + fbx);
      int j = (y1 * w + x1);

      fb->pixel[fby][fbx] = blit_op(mode, fb->pixel[fby][fbx], pxs[j]);
    }
  }
  return 1;
}

c-declare-end
)

(declare (mostly-fixnum)
	 (standard-bindings)
	 (extended-bindings)
	 (run-time-bindings)
	 (not safe))

(define framebuffer-init (c-lambda () int "init_fb"))
(define framebuffer-shutdown (c-lambda () int "shutdown_fb"))
(define framebuffer-plot (c-lambda (int int unsigned-int16) int "plot_fb"))
(define framebuffer-set-lowlight! (c-lambda (bool) int "set_lowlight_fb"))

(define framebuffer-blit
  (c-lambda (scheme-object int int int int int) int
            #<<c-lambda-end

    ___return(blit_fb(___CAST(uint16_t *,___BODY(___arg1)),
              ___arg2, ___arg3, ___arg4, ___arg5, ___arg6));

c-lambda-end
))

(define framebuffer-width 8)
(define framebuffer-height 8)

(define (make-bitmap w h)
  (make-u16vector (* w h) 0))

(define (bitmap-plot bm w h x y color)
  (u16vector-set! bm (fx+ (fx* y w) x) color))

(define (framebuffer-clear color)
  (let iter-x ((x 0))
    (if (< x framebuffer-width)
	(let iter-y ((y 0))
	  (cond ((fx< y framebuffer-height)
		 (framebuffer-plot x y color)
		 (iter-y (fx+ y 1)))
		(else
		 (iter-x (fx+ x 1))))))))

(define (scale n max+1)
  "Return a value in [0,1] representing a scaling of N within [0, MAX]"
  (inexact->exact (round (fl* (min n 1.0) (fl- (fixnum->flonum max+1) 1.0)))))

(define (rgb->val r g b)
  "Return a 565-RGB value representing R, G, and B values in [0,1]"
  (bitwise-ior (arithmetic-shift (scale r 32) 11)
               (arithmetic-shift (scale g 64) 5)
               (scale b 32)))

(define pi (fl* 2.0 (asin 1)))
(define pi/3 (fl/ pi 3.0))
(define pi*2 (fl* pi 2.0))

(define (mod2pi x)
  "Return X (a real) modulo pi times two"
  (let ((y (floor (fl/ x pi*2))))
    (fl- x (fl* pi*2 y))))

(define (mod2 x)
  "Return X (a real) modulo two"
  (let ((y (floor (fl/ x 2.0))))
    (fl- x (fl* 2.0 y))))

(define (hsv->val h s v)
  "Return a 565-RGB value representing an HSV color"
  (let* ((h (mod2pi h))
         (s (flmin 1.0 (flmax s 0.0)))
         (v (flmin 1.0 (flmax v 0.0)))
         (c (fl* v s))
         (h1 (fl/ h pi/3))
         (x (fl* c (fl- 1.0 (flabs (fl- (mod2 h1) 1.0)))))
         (m (fl- v c))
         (helper (lambda (r g b)
                   (rgb->val (fl+ r m) (fl+ g m) (fl+ b m)))))
    (cond ((fl< h1 1.0)
           (helper c x 0.0))
          ((fl< h1 2.0)
           (helper x c 0.0))
          ((fl< h1 3.0)
           (helper 0.0 c x))
          ((fl< h1 4.0)
           (helper 0.0 x c))
          ((fl< h1 5.0)
           (helper x 0.0 c))
          (else
           (helper c 0.0 x)))))

(define color-black 0)

(define max-iters 256)

(define (cell-color cr ci)
  (do ((zr 0.0 (fl+ (fl- (fl* zr zr) (fl* zi zi)) cr))
       (zi 0.0 (fl+ (fl* 2.0 zr zi) ci))
       (i 0 (fx+ i 1)))
      ((or (fx= i max-iters)
	   (fl> (fl+ (fl* zr zr) (fl* zi zi)) (flsquare 2.0)))
       (let ((iters-norm (fl/ (fixnum->flonum (fx- max-iters i))
			      (fixnum->flonum max-iters))))
	 (hsv->val (fl* pi*2 iters-norm) 1.0 iters-norm)))))

(define brot-bitmap (make-bitmap 8 8))

(define (brot cx cy scale theta)
  (let* ((cx-pxs (fl/ (fl- (fixnum->flonum framebuffer-width) 1.0) 2.0))
         (cy-pxs (fl/ (fl- (fixnum->flonum framebuffer-height) 1.0) 2.0))
	 (sin-theta (flsin theta))
	 (cos-theta (flcos theta)))
    (let iter-y ((y 0))
      (if (fx< y framebuffer-height)
          (let* ((i0 (fl* scale (fl- (fixnum->flonum y) cy-pxs))))
            (let iter-x ((x 0))
              (if (fx< x framebuffer-width)
                  (let* ((j0 (fl* scale (fl- (fixnum->flonum x) cx-pxs)))
			 (i1 (fl- (fl* cos-theta i0) (fl* sin-theta j0)))
			 (j1 (fl+ (fl* cos-theta j0) (fl* sin-theta i0)))
			 (i (fl+ cy i1))
			 (j (fl+ cx j1)))
                    (bitmap-plot brot-bitmap 8 8 x y (cell-color i j))
		    (iter-x (fx+ x 1)))
		  (iter-y (fx+ y 1)))))
	  (framebuffer-blit brot-bitmap 8 8 0 0 0)))))

(define (iter-brot cx cy begin-scale scale-step begin-theta theta-step iters)
  (do ((scale begin-scale (fl* scale scale-step))
       (theta begin-theta (mod2pi (fl+ theta theta-step)))
       (i 0 (fx+ i 1)))
      ((fx= i iters))
    (brot cx cy scale theta)))

(define (test-iter-brot)
  (framebuffer-init)
  (framebuffer-set-lowlight! #t)
  (do () (#f)
    (iter-brot 6.77636708120639e-4 -1.57497160008726
	       1.0e1 0.995
	       0.0 0.1
	       4500)))
