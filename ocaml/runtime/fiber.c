/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*      KC Sivaramakrishnan, Indian Institute of Technology, Madras       */
/*                   Tom Kelly, OCaml Labs Consultancy                    */
/*                Stephen Dolan, University of Cambridge                  */
/*                                                                        */
/*   Copyright 2021 Indian Institute of Technology, Madras                */
/*   Copyright 2021 OCaml Labs Consultancy                                */
/*   Copyright 2019 University of Cambridge                               */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

#define CAML_INTERNALS

#include <string.h>
#include <unistd.h>
#include "caml/alloc.h"
#include "caml/callback.h"
#include "caml/codefrag.h"
#include "caml/fail.h"
#include "caml/fiber.h"
#include "caml/gc_ctrl.h"
#include "caml/platform.h"
#include "caml/minor_gc.h"
#include "caml/misc.h"
#include "caml/major_gc.h"
#include "caml/memory.h"
#include "caml/startup_aux.h"
#include "caml/shared_heap.h"
#ifdef NATIVE_CODE
#include "caml/stack.h"
#include "caml/frame_descriptors.h"
#endif
#if defined(USE_MMAP_MAP_STACK) || !defined(STACK_CHECKS_ENABLED)
#include <sys/mman.h>
#endif

#ifdef DEBUG
#define fiber_debug_log(...) caml_gc_log(__VA_ARGS__)
#else
#define fiber_debug_log(...)
#endif

static _Atomic int64_t fiber_id = 0;

uintnat caml_get_init_stack_wsize (int thread_stack_wsz)
{
#if defined(NATIVE_CODE) && !defined(STACK_CHECKS_ENABLED)
  uintnat init_stack_wsize =
    thread_stack_wsz < 0
    ? caml_params->init_main_stack_wsz
    : caml_params->init_thread_stack_wsz > 0
    ? caml_params->init_thread_stack_wsz : thread_stack_wsz;
#else
  (void) thread_stack_wsz;
  uintnat init_stack_wsize = Wsize_bsize(Stack_init_bsize);
#endif
  uintnat stack_wsize;

  if (init_stack_wsize < caml_max_stack_wsize)
    stack_wsize = init_stack_wsize;
  else
    stack_wsize = caml_max_stack_wsize;

  return stack_wsize;
}

void caml_change_max_stack_size (uintnat new_max_wsize)
{
  struct stack_info *current_stack = Caml_state->current_stack;
  asize_t wsize = Stack_high(current_stack) - (value*)current_stack->sp
                 + Stack_threshold / sizeof (value);

  if (new_max_wsize < wsize) new_max_wsize = wsize;
  if (new_max_wsize != caml_max_stack_wsize){
    caml_gc_log ("Changing stack limit to %"
                 ARCH_INTNAT_PRINTF_FORMAT "uk bytes",
                     new_max_wsize * sizeof (value) / 1024);
  }
  caml_max_stack_wsize = new_max_wsize;
}

#define NUM_STACK_SIZE_CLASSES 5

struct stack_info** caml_alloc_stack_cache (void)
{
  int i;

  struct stack_info** stack_cache =
    (struct stack_info**)caml_stat_alloc_noexc(sizeof(struct stack_info*) *
                                               NUM_STACK_SIZE_CLASSES);
  if (stack_cache == NULL)
    return NULL;

  for(i = 0; i < NUM_STACK_SIZE_CLASSES; i++)
    stack_cache[i] = NULL;

  return stack_cache;
}

Caml_inline struct stack_info* alloc_for_stack (mlsize_t wosize)
{
#ifdef USE_MMAP_MAP_STACK
  size_t len = sizeof(struct stack_info) +
               sizeof(value) * wosize +
               8 /* for alignment to 16-bytes, needed for arm64 */ +
               sizeof(struct stack_handler);
  struct stack_info* si;
  si = mmap(NULL, len, PROT_WRITE | PROT_READ,
             MAP_ANONYMOUS | MAP_PRIVATE | MAP_STACK, -1, 0);
  if (si == MAP_FAILED)
    return NULL;

  si->size = len;
  return si;
#else
#if defined(NATIVE_CODE) && !defined(STACK_CHECKS_ENABLED)
  /* (We use the following strategy only in native code, because bytecode
   * has its own way of dealing with stack checks.)
   *
   * We want to detect a stack overflow by triggering a segfault when a
   * given part of the memory is accessed; in order to do so, we protect
   * a page near the end of the stack to make it unreadable/unwritable.
   * A signal handler for segfault will be installed, that will check if
   * the invalid address is in the range we protect, and will raise a stack
   * overflow exception accordingly.
   *
   * The sequence of steps to achieve that is loosely based on the glibc
   * code (See nptl/allocatestack.c):
   * - first, we mmap the memory for the stack, with PROT_NONE so that
   *   the allocated memory is not committed;
   * - second, we madvise to not use huge pages for this memory chunk;
   * - third, we restore the read/write permissions for the whole memory
   *   chunk;
   * - finally, we disable the read/write permissions again, but only
   *   for the page that will act as the guard.
   *
   * The reasoning behind this convoluted process is that if we only
   * mmap and then mprotect, we incur the risk of splitting a huge page
   * and losing its benefits while causing more bookkeeping.
   */
  size_t bsize = Bsize_wsize(wosize);
  int page_size = getpagesize();
  int num_pages = (bsize + page_size - 1) / page_size;
  bsize = (num_pages + 2) * page_size;
  size_t len = sizeof(struct stack_info) +
               bsize +
               8 /* for alignment to 16-bytes, needed for arm64 */ +
               sizeof(struct stack_handler);
  struct stack_info* block;
  block = mmap(NULL, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
  if (block == MAP_FAILED) {
    return NULL;
  }
  if (madvise (block, len, MADV_NOHUGEPAGE)) {
    munmap(block, len);
    return NULL;
  }
  if (mprotect(block, len, PROT_READ | PROT_WRITE)) {
    munmap(block, len);
    return NULL;
  }
  if (mprotect((char *) block + page_size, page_size, PROT_NONE)) {
    munmap(block, len);
    return NULL;
  }
  block->size = len;
  return block;
#else
  size_t len = sizeof(struct stack_info) +
               sizeof(value) * wosize +
               8 /* for alignment to 16-bytes, needed for arm64 */ +
               sizeof(struct stack_handler);
  return caml_stat_alloc_noexc(len);
#endif /* NATIVE_CODE */
#endif /* USE_MMAP_MAP_STACK */
}

/* Returns the index into the [Caml_state->stack_cache] array if this size is
 * pooled. If unpooled, it is [-1].
 *
 * Stacks may be unpooled if either the stack size is not 2**N multiple of
 * [caml_fiber_wsz] or the stack is bigger than pooled sizes. */
Caml_inline int stack_cache_bucket (mlsize_t wosize) {
  mlsize_t size_bucket_wsz = caml_fiber_wsz;
  int bucket=0;

  while (bucket < NUM_STACK_SIZE_CLASSES) {
    if (wosize == size_bucket_wsz)
      return bucket;
    ++bucket;
    size_bucket_wsz += size_bucket_wsz;
  }

  return -1;
}

static struct stack_info*
alloc_size_class_stack_noexc(mlsize_t wosize, int cache_bucket, value hval,
                             value hexn, value heff, int64_t id)
{
  struct stack_info* stack;
  struct stack_handler* hand;
  struct stack_info **cache = Caml_state->stack_cache;

  CAML_STATIC_ASSERT(sizeof(struct stack_info) % sizeof(value) == 0);
  CAML_STATIC_ASSERT(sizeof(struct stack_handler) % sizeof(value) == 0);

  CAMLassert(cache != NULL);

  if (cache_bucket != -1 &&
      cache[cache_bucket] != NULL) {
    stack = cache[cache_bucket];
    cache[cache_bucket] =
      (struct stack_info*)stack->exception_ptr;
    CAMLassert(stack->cache_bucket == stack_cache_bucket(wosize));
    hand = stack->handler;
  } else {
    /* couldn't get a cached stack, so have to create one */
    stack = alloc_for_stack(wosize);
    if (stack == NULL) {
      return NULL;
    }

    stack->cache_bucket = cache_bucket;

    /* Ensure 16-byte alignment because some architectures require it */
    hand = (struct stack_handler*)
     (((uintnat)stack + sizeof(struct stack_info) + sizeof(value) * wosize + 8)
      & ((uintnat)-1 << 4));
    stack->handler = hand;
  }

  hand->handle_value = hval;
  hand->handle_exn = hexn;
  hand->handle_effect = heff;
  hand->parent = NULL;
  stack->sp = (value*)hand;
  stack->exception_ptr = NULL;
  stack->id = id;
#ifdef DEBUG
  stack->magic = 42;
#endif
  CAMLassert(Stack_high(stack) - Stack_base(stack) == wosize ||
             Stack_high(stack) - Stack_base(stack) == wosize + 1);
  return stack;

}

/* allocate a stack with at least "wosize" usable words of stack */
struct stack_info*
caml_alloc_stack_noexc(mlsize_t wosize, value hval, value hexn, value heff,
                       int64_t id)
{
  int cache_bucket = stack_cache_bucket (wosize);
  return alloc_size_class_stack_noexc(wosize, cache_bucket, hval, hexn, heff,
                                      id);
}

#ifdef NATIVE_CODE

value caml_alloc_stack (value hval, value hexn, value heff) {
  const int64_t id = atomic_fetch_add(&fiber_id, 1);
  struct stack_info* stack =
    alloc_size_class_stack_noexc(caml_fiber_wsz, 0 /* first bucket */,
                                 hval, hexn, heff, id);

  if (!stack) caml_raise_out_of_memory();

  fiber_debug_log ("Allocate stack=%p of %" ARCH_INTNAT_PRINTF_FORMAT
                     "u words", stack, caml_fiber_wsz);

  return Val_ptr(stack);
}


void caml_get_stack_sp_pc (struct stack_info* stack,
                           char** sp /* out */, uintnat* pc /* out */)
{
  char* p = (char*)stack->sp;

  Pop_frame_pointer(p);
  *pc = *(uintnat*)p; /* ret addr */
  *sp = p + sizeof(value);
}


/* Returns the arena number of a block,
   or -1 if it is not in any local arena */
static int get_local_ix(caml_local_arenas* loc, value v)
{
  int i;
  CAMLassert(Is_block(v));
  /* Search local arenas, starting from the largest (last) */
  for (i = 0; i < loc->count; i++) {
    struct caml_local_arena arena = loc->arenas[i];
    if (arena.base <= (char*)v && (char*)v < arena.base + arena.length)
      return i;
  }
  return -1;
}


/* If it visits an unmarked local block,
      returns the index of the containing arena
   Otherwise returns -1.
   Temporarily marks local blocks with colors.GARBAGE
    (which is not otherwise the color of reachable blocks) */
static int visit(scanning_action f, void* fdata,
                 struct caml_local_arenas* locals,
                 struct global_heap_state colors,
                 value* p)
{
  value v = *p, vblock = v;
  header_t hd;
  int ix;
  if (!Is_block(v))
    return -1;

  if (Is_young(v)) {
    f(fdata, v, p);
    return -1;
  }

  /* major or local or external */

  hd = Hd_val(vblock);
  if (Tag_hd(hd) == Infix_tag) {
    vblock -= Infix_offset_val(v);
    hd = Hd_val(vblock);
  }

  if (Color_hd(hd) == colors.GARBAGE) {
    /* Local, marked */
    return -1;
  } else if (Color_hd(hd) == NOT_MARKABLE) {
    /* Local (unmarked) or external */

    if (locals == NULL)
      /* external */
      return -1;

    ix = get_local_ix(locals, vblock);

    if (ix != -1) {
      /* Mark this unmarked local */
      *Hp_val(vblock) = With_status_hd(hd, colors.GARBAGE);
    }

    return ix;
  } else {
    /* Major heap */
    f(fdata, v, p);
    return -1;
  }
}

static void scan_local_allocations(scanning_action f, void* fdata,
                                   caml_local_arenas* loc)
{
  int arena_ix;
  intnat sp;
  struct caml_local_arena arena;
  /* does not change during scanning */
  struct global_heap_state colors = caml_global_heap_state;

  if (loc == NULL) return;
  CAMLassert(loc->count > 0);
  sp = loc->saved_sp;
  arena_ix = loc->count - 1;
  arena = loc->arenas[arena_ix];
#ifdef DEBUG
  { header_t* hp;
    for (hp = (header_t*)arena.base;
         hp < (header_t*)(arena.base + arena.length + sp);
         hp++) {
      *hp = Debug_free_local;
    }
  }
#endif

  while (sp < 0) {
    header_t* hp = (header_t*)(arena.base + arena.length + sp), hd = *hp;
    intnat i;

    if (hd == Local_uninit_hd) {
      CAMLassert(arena_ix > 0);
      arena = loc->arenas[--arena_ix];
#ifdef DEBUG
      for (hp = (header_t*)arena.base;
           hp < (header_t*)(arena.base + arena.length + sp);
           hp++) {
        *hp = Debug_free_local;
      }
#endif
      continue;
    }
    CAMLassert(Color_hd(hd) == NOT_MARKABLE ||
               Color_hd(hd) == colors.GARBAGE);
    if (Color_hd(hd) == NOT_MARKABLE) {
      /* Local allocation, not marked */
#ifdef DEBUG
      /* We don't check the reserved bits here because this is OK even for mixed
         blocks. */
      for (i = 0; i < Wosize_hd(hd); i++)
        Field(Val_hp(hp), i) = Debug_free_local;
#endif
      sp += Bhsize_hd(hd);
      continue;
    }
    /* reset mark */
    hd = With_status_hd(hd, NOT_MARKABLE);
    *hp = hd;
    CAMLassert(Tag_hd(hd) != Infix_tag);  /* start of object, no infix */
    CAMLassert(Tag_hd(hd) != Cont_tag);   /* no local continuations */
    if (Tag_hd(hd) >= No_scan_tag) {
      sp += Bhsize_hd(hd);
      continue;
    }
    i = 0;
    if (Tag_hd(hd) == Closure_tag)
      i = Start_env_closinfo(Closinfo_val(Val_hp(hp)));

    mlsize_t scannable_wosize = Scannable_wosize_hd(hd);

    for (; i < scannable_wosize; i++) {
      value *p = Op_val(Val_hp(hp)) + i;
      int marked_ix = visit(f, fdata, loc, colors, p);
      if (marked_ix != -1) {
        struct caml_local_arena a = loc->arenas[marked_ix];
        intnat newsp = (char*)*p - (a.base + a.length);
        if (sp <= newsp) {
          /* forwards pointer, common case */
          CAMLassert(marked_ix <= arena_ix);
        } else {
          /* If backwards pointers are ever supported (e.g. local recursive
             values), then this should reset sp and iterate to a fixpoint */
          CAMLassert(marked_ix >= arena_ix);
          caml_fatal_error("backwards local pointer");
        }
      }
    }
    sp += Bhsize_hd(hd);
  }
}


Caml_inline void scan_stack_frames(
  scanning_action f, scanning_action_flags fflags, void* fdata,
  struct stack_info* stack, value* gc_regs,
  struct caml_local_arenas* locals)
{
  char * sp;
  uintnat retaddr;
  value * regs;
  frame_descr * d;
  value *root;
  caml_frame_descrs fds = caml_get_frame_descrs();
  /* does not change during marking */
  struct global_heap_state colors = caml_global_heap_state;

  sp = (char*)stack->sp;
  regs = gc_regs;

next_chunk:
  if (sp == (char*)Stack_high(stack)) return;

  Pop_frame_pointer(sp);
  retaddr = *(uintnat*)sp;
  sp += sizeof(value);

  while(1) {
    d = caml_find_frame_descr(fds, retaddr);
    CAMLassert(d);
    if (!frame_return_to_C(d)) {
      /* Scan the roots in this frame */
      if (frame_is_long(d)) {
        frame_descr_long *dl = frame_as_long(d);
        uint32_t *p;
        uint32_t n;
        for (p = dl->live_ofs, n = dl->num_live; n > 0; n--, p++) {
          uint32_t ofs = *p;
          if (ofs & 1) {
            root = regs + (ofs >> 1);
          } else {
            root = (value *)(sp + ofs);
          }
          visit (f, fdata, locals, colors, root);
        }
      } else {
        uint16_t *p;
        uint16_t n;
        for (p = d->live_ofs, n = d->num_live; n > 0; n--, p++) {
          uint16_t ofs = *p;
          if (ofs & 1) {
            root = regs + (ofs >> 1);
          } else {
            root = (value *)(sp + ofs);
          }
          visit (f, fdata, locals, colors, root);
        }
      }
      /* Move to next frame */
      sp += frame_size(d);
      retaddr = Saved_return_address(sp);
      /* XXX KC: disabled already scanned optimization. */
    } else {
      /* This marks the top of an ML stack chunk. Move sp to the previous
       * stack chunk.  */
      sp += 3 * sizeof(value); /* trap frame & DWARF pointer */
      regs = *(value**)sp;     /* update gc_regs */
      sp += 1 * sizeof(value); /* gc_regs */
      goto next_chunk;
    }
  }
}

void caml_scan_stack(
  scanning_action f, scanning_action_flags fflags, void* fdata,
  struct stack_info* stack, value* gc_regs,
  struct caml_local_arenas* locals)
{
  while (stack != NULL) {
    scan_stack_frames(f, fflags, fdata, stack, gc_regs, locals);

    f(fdata, Stack_handle_value(stack), &Stack_handle_value(stack));
    f(fdata, Stack_handle_exception(stack), &Stack_handle_exception(stack));
    f(fdata, Stack_handle_effect(stack), &Stack_handle_effect(stack));

    stack = Stack_parent(stack);
  }
}

void caml_maybe_expand_stack (void)
{
  struct stack_info* stk = Caml_state->current_stack;
  uintnat stack_available =
    (value*)stk->sp - Stack_base(stk);
  uintnat stack_needed =
    Stack_threshold / sizeof(value)
    + 10 /* for words pushed by caml_start_program */;
  /* XXX does this "8" need updating?  Provisionally changed to 10 */

  if (stack_available < stack_needed)
    if (!caml_try_realloc_stack (stack_needed))
      caml_raise_stack_overflow();

  if (Caml_state->gc_regs_buckets == NULL) {
    /* Ensure there is at least one gc_regs bucket available before
       running any OCaml code. See fiber.h for documentation. */
    value* bucket = caml_stat_alloc(sizeof(value) * Wosize_gc_regs);
    bucket[0] = 0; /* no next bucket */
    Caml_state->gc_regs_buckets = bucket;
  }
}

#else /* End NATIVE_CODE, begin BYTE_CODE */

value caml_global_data;

CAMLprim value caml_alloc_stack(value hval, value hexn, value heff)
{
  value* sp;
  const int64_t id = atomic_fetch_add(&fiber_id, 1);
  struct stack_info* stack =
    alloc_size_class_stack_noexc(caml_fiber_wsz, 0 /* first bucket */,
                                 hval, hexn, heff, id);

  if (!stack) caml_raise_out_of_memory();

  sp = Stack_high(stack);
  sp -= 1;
  sp[0] = Val_long(1);

  stack->sp = sp;

  return Val_ptr(stack);
}

CAMLprim value caml_ensure_stack_capacity(value required_space)
{
  asize_t req = Long_val(required_space);
  if (Caml_state->current_stack->sp - req <
      Stack_base(Caml_state->current_stack))
    if (!caml_try_realloc_stack(req))
      caml_raise_stack_overflow();
  return Val_unit;
}

/*
  Root scanning.

  Used by the GC to find roots on the stacks of running or runnable fibers.
*/

/* Code pointers are stored on the bytecode stack as naked pointers.
   We must avoid passing them to the scanning action,
   unless we know that it is a no-op outside young values
   (so it will safely ignore code pointers). */
 Caml_inline int is_scannable(scanning_action_flags flags, value v) {
  return
      (flags & SCANNING_ONLY_YOUNG_VALUES)
      || (Is_block(v) && caml_find_code_fragment_by_pc((char *) v) == NULL);
}

void caml_scan_stack(
  scanning_action f, scanning_action_flags fflags, void* fdata,
  struct stack_info* stack, value* v_gc_regs,
  struct caml_local_arenas* unused)
{
  value *low, *high, *sp;

  while (stack != NULL) {
    CAMLassert(stack->magic == 42);

    high = Stack_high(stack);
    low = stack->sp;
    for (sp = low; sp < high; sp++) {
      value v = *sp;
      if (is_scannable(fflags, v)) {
        f(fdata, v, sp);
      }
    }

    if (is_scannable(fflags, Stack_handle_value(stack)))
      f(fdata, Stack_handle_value(stack), &Stack_handle_value(stack));
    if (is_scannable(fflags, Stack_handle_exception(stack)))
      f(fdata, Stack_handle_exception(stack), &Stack_handle_exception(stack));
    if (is_scannable(fflags, Stack_handle_effect(stack)))
      f(fdata, Stack_handle_effect(stack), &Stack_handle_effect(stack));

    stack = Stack_parent(stack);
  }
}

#endif /* end BYTE_CODE */

CAMLexport void caml_do_local_roots (
  scanning_action f, scanning_action_flags fflags, void* fdata,
  struct caml__roots_block *local_roots,
  struct stack_info *current_stack,
  value * v_gc_regs,
  struct caml_local_arenas* locals)
{
  struct caml__roots_block *lr;
  int i, j;
  value* sp;

  for (lr = local_roots; lr != NULL; lr = lr->next) {
    for (i = 0; i < lr->ntables; i++){
      for (j = 0; j < lr->nitems; j++){
        sp = &(lr->tables[i][j]);
        if (*sp != 0) {
#ifdef NATIVE_CODE
          visit (f, fdata, locals, caml_global_heap_state, sp);
#else
          f (fdata, *sp, sp);
#endif
        }
      }
    }
  }
  caml_scan_stack(f, fflags, fdata, current_stack, v_gc_regs, locals);
#ifdef NATIVE_CODE
  scan_local_allocations(f, fdata, locals);
#else
  CAMLassert(locals == NULL);
#endif
}


/*
  Stack management.

  Used by the interpreter to allocate stack space.
*/

#ifdef NATIVE_CODE
/* Update absolute exception pointers for new stack*/
void caml_rewrite_exception_stack(struct stack_info *old_stack,
                                  value** exn_ptr, value** async_exn_ptr,
                                  struct stack_info *new_stack)
{
  fiber_debug_log("Old [%p, %p]", Stack_base(old_stack), Stack_high(old_stack));
  fiber_debug_log("New [%p, %p]", Stack_base(new_stack), Stack_high(new_stack));
  if(exn_ptr) {
    CAMLassert(async_exn_ptr != NULL);

    fiber_debug_log ("*exn_ptr=%p", *exn_ptr);
    fiber_debug_log ("*async_exn_ptr=%p", *async_exn_ptr);

    while (Stack_base(old_stack) < *exn_ptr &&
           *exn_ptr <= Stack_high(old_stack)) {
      int must_update_async_exn_ptr = *exn_ptr == *async_exn_ptr;
#ifdef DEBUG
      value* old_val = *exn_ptr;
#endif
      *exn_ptr = Stack_high(new_stack) - (Stack_high(old_stack) - *exn_ptr);

      if (must_update_async_exn_ptr) *async_exn_ptr = *exn_ptr;
      fiber_debug_log ("must_update_async_exn_ptr=%d",
        must_update_async_exn_ptr);

      fiber_debug_log ("Rewriting %p to %p", old_val, *exn_ptr);

      CAMLassert(Stack_base(new_stack) < *exn_ptr);
      CAMLassert((value*)*exn_ptr <= Stack_high(new_stack));

      exn_ptr = (value**)*exn_ptr;
    }
    fiber_debug_log ("finished with *exn_ptr=%p", *exn_ptr);
  } else {
    fiber_debug_log ("exn_ptr is null");
    CAMLassert(async_exn_ptr == NULL);
  }
}

#ifdef WITH_FRAME_POINTERS
/* Update absolute base pointers for new stack */
static void rewrite_frame_pointers(struct stack_info *old_stack,
    struct stack_info *new_stack)
{
  struct frame_walker {
    struct frame_walker *base_addr;
    uintnat return_addr;
  } *frame, *next;
  ssize_t delta;
  void *top, **p;

  delta = (char*)Stack_high(new_stack) - (char*)Stack_high(old_stack);

  /* Walk the frame-pointers linked list */
  for (frame = __builtin_frame_address(0); frame; frame = next) {

    top = (char*)&frame->return_addr
      + 1 * sizeof(value) /* return address */
      + 2 * sizeof(value) /* trap frame */
      + 2 * sizeof(value); /* DWARF pointer & gc_regs */

    /* Detect top of the fiber and bail out */
    /* It also avoid to dereference invalid base pointer at main */
    if (top == Stack_high(old_stack))
      break;

    /* Save the base address since it may be adjusted */
    next = frame->base_addr;

    if (!(Stack_base(old_stack) <= (value*)frame->base_addr
        && (value*)frame->base_addr < Stack_high(old_stack))) {
      /* No need to adjust base pointers that don't point into the reallocated
       * fiber */
      continue;
    }

    if (Stack_base(old_stack) <= (value*)&frame->base_addr
        && (value*)&frame->base_addr < Stack_high(old_stack)) {
      /* The base pointer itself is located inside the reallocated fiber
       * and needs to be adjusted on the new fiber */
      p = (void**)((char*)Stack_high(new_stack) - (char*)Stack_high(old_stack)
          + (char*)&frame->base_addr);
      CAMLassert(*p == frame->base_addr);
      *p += delta;
    }
    else {
      /* Base pointers on other stacks are adjusted in place */
      frame->base_addr = (struct frame_walker*)((char*)frame->base_addr
          + delta);
    }
  }
}
#endif
#endif

int caml_try_realloc_stack(asize_t required_space)
{
#if defined(NATIVE_CODE) && !defined(STACK_CHECKS_ENABLED)
  (void) required_space;
  abort();
#else
  struct stack_info *old_stack, *new_stack;
  asize_t wsize;
  int stack_used;
  CAMLnoalloc;

  old_stack = Caml_state->current_stack;
  stack_used = Stack_high(old_stack) - (value*)old_stack->sp;
  wsize = Stack_high(old_stack) - Stack_base(old_stack);
  do {
    if (wsize >= caml_max_stack_wsize) return 0;
    wsize *= 2;
  } while (wsize < stack_used + required_space);

  if (wsize > 4096 / sizeof(value)) {
    caml_gc_log ("Growing stack to %"
                 ARCH_INTNAT_PRINTF_FORMAT "uk bytes",
                 (uintnat) wsize * sizeof(value) / 1024);
  } else {
    caml_gc_log ("Growing stack to %"
                 ARCH_INTNAT_PRINTF_FORMAT "u bytes",
                 (uintnat) wsize * sizeof(value));
  }

  new_stack = caml_alloc_stack_noexc(wsize,
                                     Stack_handle_value(old_stack),
                                     Stack_handle_exception(old_stack),
                                     Stack_handle_effect(old_stack),
                                     old_stack->id);

  if (!new_stack) return 0;
  memcpy(Stack_high(new_stack) - stack_used,
         Stack_high(old_stack) - stack_used,
         stack_used * sizeof(value));
  new_stack->sp = Stack_high(new_stack) - stack_used;
  Stack_parent(new_stack) = Stack_parent(old_stack);
#ifdef NATIVE_CODE
  /* There's no need to do another pass rewriting from
     Caml_state->async_exn_handler because every asynchronous exception trap
     frame is also a normal exception trap frame.  However
     Caml_state->async_exn_handler itself must be updated. */
  caml_rewrite_exception_stack(old_stack, (value**)&Caml_state->exn_handler,
                               (value**) &Caml_state->async_exn_handler,
                               new_stack);
#ifdef WITH_FRAME_POINTERS
  rewrite_frame_pointers(old_stack, new_stack);
#endif
#endif

  /* Update stack pointers in Caml_state->c_stack. It is possible to have
   * multiple c_stack_links to point to the same stack since callbacks are run
   * on existing stacks. */
  {
    struct c_stack_link* link;
    for (link = Caml_state->c_stack; link; link = link->prev) {
      if (link->stack == old_stack) {
        link->stack = new_stack;
        link->sp = (void*)((char*)Stack_high(new_stack) -
                           ((char*)Stack_high(old_stack) - (char*)link->sp));
      }
      if (link->async_exn_handler >= (char*) Stack_base(old_stack)
          && link->async_exn_handler < (char*) Stack_high(old_stack)) {
        /* The asynchronous exception trap frame pointed to by the current
           c_stack_link lies on the OCaml stack being reallocated.  Repoint the
           trap frame to the new stack. */
        fiber_debug_log("Rewriting link->async_exn_handler %p...",
          link->async_exn_handler);
        link->async_exn_handler +=
          (char*) Stack_high(new_stack) - (char*) Stack_high(old_stack);
        fiber_debug_log("...to %p", link->async_exn_handler);
      } else {
        fiber_debug_log("Not touching link->async_exn_handler %p",
          link->async_exn_handler);
      }
    }
  }

  caml_free_stack(old_stack);
  Caml_state->current_stack = new_stack;
  return 1;
#endif
}

struct stack_info* caml_alloc_main_stack (uintnat init_wsize)
{
  const int64_t id = atomic_fetch_add(&fiber_id, 1);
  struct stack_info* stk =
    caml_alloc_stack_noexc(init_wsize, Val_unit, Val_unit, Val_unit, id);
  return stk;
}

void caml_free_stack (struct stack_info* stack)
{
  CAMLnoalloc;
  struct stack_info** cache = Caml_state->stack_cache;

  CAMLassert(stack->magic == 42);
  CAMLassert(cache != NULL);

#ifndef USE_MMAP_MAP_STACK
#if defined(NATIVE_CODE) && !defined(STACK_CHECKS_ENABLED)
  int page_size = getpagesize();
  mprotect((void *) ((char *) stack + page_size),
           page_size,
           PROT_READ | PROT_WRITE);
#endif
#endif

  if (stack->cache_bucket != -1) {
    stack->exception_ptr =
      (void*)(cache[stack->cache_bucket]);
    cache[stack->cache_bucket] = stack;
#ifdef DEBUG
    memset(Stack_base(stack), 0x42,
           (Stack_high(stack)-Stack_base(stack))*sizeof(value));
#endif
  } else {
#ifdef DEBUG
    memset(stack, 0x42, (char*)stack->handler - (char*)stack);
#endif
#ifdef USE_MMAP_MAP_STACK
    munmap(stack, stack->size);
#else
#if defined(NATIVE_CODE) && !defined(STACK_CHECKS_ENABLED)
    munmap(stack, stack->size);
#else
    caml_stat_free(stack);
#endif
#endif
  }
}

void caml_free_gc_regs_buckets(value *gc_regs_buckets)
{
  while (gc_regs_buckets != NULL) {
    value *next = (value*)gc_regs_buckets[0];
    caml_stat_free(gc_regs_buckets);
    gc_regs_buckets = next;
  }
}


CAMLprim value caml_continuation_use_noexc (value cont)
{
  value v;
  value null_stk = Val_ptr(NULL);
  CAMLnoalloc;

  fiber_debug_log("cont: is_block(%d) tag_val(%ul) is_young(%d)",
                  Is_block(cont), Tag_val(cont), Is_young(cont));
  CAMLassert(Is_block(cont) && Tag_val(cont) == Cont_tag);

  /* this forms a barrier between execution and any other domains
     that might be marking this continuation */
  if (!Is_young(cont) && caml_marking_started())
    caml_darken_cont(cont);

  v = Field(cont, 0);

  if (caml_domain_alone()) {
    Field(cont, 0) = null_stk;
    return v;
  }

  if (atomic_compare_exchange_strong(Op_atomic_val(cont), &v, null_stk)) {
    return v;
  } else {
    return null_stk;
  }
}

CAMLprim value caml_continuation_use (value cont)
{
  value v = caml_continuation_use_noexc(cont);
  if (v == Val_ptr(NULL))
    caml_raise_continuation_already_resumed();
  return v;
}

CAMLprim value caml_continuation_use_and_update_handler_noexc
  (value cont, value hval, value hexn, value heff)
{
  value stack;
  struct stack_info* stk;

  stack = caml_continuation_use_noexc (cont);
  stk = Ptr_val(stack);
  if (stk == NULL) {
    /* The continuation has already been taken */
    return stack;
  }
  while (Stack_parent(stk) != NULL) stk = Stack_parent(stk);
  Stack_handle_value(stk) = hval;
  Stack_handle_exception(stk) = hexn;
  Stack_handle_effect(stk) = heff;
  return stack;
}

void caml_continuation_replace(value cont, struct stack_info* stk)
{
  value n = Val_ptr(NULL);
  int b = atomic_compare_exchange_strong(Op_atomic_val(cont), &n, Val_ptr(stk));
  CAMLassert(b);
  (void)b; /* squash unused warning */
}

CAMLprim value caml_drop_continuation (value cont)
{
  struct stack_info* stk = Ptr_val(caml_continuation_use(cont));
  caml_free_stack(stk);
  return Val_unit;
}

static const value * _Atomic caml_unhandled_effect_exn = NULL;
static const value * _Atomic caml_continuation_already_resumed_exn = NULL;

static const value * cache_named_exception(const value * _Atomic * cache,
                                           const char * name)
{
  const value * exn;
  exn = atomic_load_acquire(cache);
  if (exn == NULL) {
    exn = caml_named_value(name);
    if (exn == NULL) {
      fprintf(stderr, "Fatal error: exception %s\n", name);
      exit(2);
    }
    atomic_store_release(cache, exn);
  }
  return exn;
}

CAMLexport void caml_raise_continuation_already_resumed(void)
{
  const value * exn =
    cache_named_exception(&caml_continuation_already_resumed_exn,
                          "Effect.Continuation_already_resumed");
  caml_raise(*exn);
}

value caml_make_unhandled_effect_exn (value effect)
{
  CAMLparam1(effect);
  value res;
  const value * exn =
    cache_named_exception(&caml_unhandled_effect_exn, "Effect.Unhandled");
  res = caml_alloc_small(2,0);
  Field(res, 0) = *exn;
  Field(res, 1) = effect;
  CAMLreturn(res);
}

CAMLexport void caml_raise_unhandled_effect (value effect)
{
  caml_raise(caml_make_unhandled_effect_exn(effect));
}
