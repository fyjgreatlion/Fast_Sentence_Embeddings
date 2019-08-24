#!/usr/bin/env cython
# cython: boundscheck=False
# cython: wraparound=False
# cython: cdivision=True
# cython: embedsignature=True
# coding: utf-8

# Author: Oliver Borchers <borchers@bwl.uni-mannheim.de>
# Copyright (C) 2019 Oliver Borchers

"""Optimized cython functions for computing sentence embeddings"""

import cython
import numpy as np

cimport numpy as np

from gensim.models._utils_any2vec import compute_ngrams_bytes, ft_hash_bytes

from libc.string cimport memset

import scipy.linalg.blas as fblas

cdef saxpy_ptr saxpy=<saxpy_ptr>PyCObject_AsVoidPtr(fblas.saxpy._cpointer)  # y += alpha * x
cdef sscal_ptr sscal=<sscal_ptr>PyCObject_AsVoidPtr(fblas.sscal._cpointer) # x = alpha * x

cdef int ONE = <int>1
cdef int ZERO = <int>0

cdef REAL_t ONEF = <REAL_t>1.0
cdef REAL_t ZEROF = <REAL_t>0.0

DEF MAX_WORDS = 10000
DEF MAX_NGRAMS = 40

cdef init_base_s2v_config(BaseSentenceVecsConfig *c, model, target):
    c[0].workers = model.workers
    c[0].size = model.sv.vector_size

    c[0].word_vectors = <REAL_t *>(np.PyArray_DATA(model.wv.vectors))
    c[0].word_weights = <REAL_t *>(np.PyArray_DATA(model.word_weights))

    c[0].sentence_vectors = <REAL_t *>(np.PyArray_DATA(target))

cdef init_ft_s2v_config(FTSentenceVecsConfig *c, model, target, memory):

    c[0].workers = model.workers
    c[0].size = model.sv.vector_size
    c[0].min_n = model.wv.min_n
    c[0].max_n = model.wv.max_n
    c[0].bucket = model.wv.bucket

    c[0].oov_weight = np.max(model.word_weights)

    c[0].mem = <REAL_t *>(np.PyArray_DATA(memory[0]))
    c[0].subwords_idx = <uINT_t *>(np.PyArray_DATA(memory[1]))

    c[0].word_vectors = <REAL_t *>(np.PyArray_DATA(model.wv.vectors_vocab))
    c[0].ngram_vectors = <REAL_t *>(np.PyArray_DATA(model.wv.vectors_ngrams))
    c[0].word_weights = <REAL_t *>(np.PyArray_DATA(model.word_weights))

    c[0].sentence_vectors = <REAL_t *>(np.PyArray_DATA(target))

cdef object populate_base_s2v_config(BaseSentenceVecsConfig *c, vocab, indexed_sentences):

    cdef uINT_t eff_words = ZERO    # Effective words encountered in a sentence
    cdef uINT_t eff_sents = ZERO    # Effective sentences encountered

    c.sentence_boundary[0] = ZERO

    for obj in indexed_sentences:
        if not obj.words:
            continue
        for token in obj.words:
            word = vocab[token] if token in vocab else None # Vocab obj
            if word is None:
                continue
            c.word_indices[eff_words] = <uINT_t>word.index
            c.sent_adresses[eff_words] = <uINT_t>obj.index

            eff_words += ONE
            if eff_words == MAX_WORDS:
                break
        
        eff_sents += 1
        c.sentence_boundary[eff_sents] = eff_words

        if eff_words == MAX_WORDS:
            break   

    return eff_sents, eff_words

cdef object populate_ft_s2v_config(FTSentenceVecsConfig *c, vocab, indexed_sentences):

    cdef uINT_t eff_words = ZERO    # Effective words encountered in a sentence
    cdef uINT_t eff_sents = ZERO    # Effective sentences encountered

    c.sentence_boundary[0] = ZERO

    for obj in indexed_sentences:
        if not obj.words:
            continue
        for token in obj.words:
            c.sent_adresses[eff_words] = <uINT_t>obj.index

            if token in vocab:
                # In Vocabulary
                word = vocab[token]
                c.word_indices[eff_words] = <uINT_t>word.index    
                c.subwords_idx_len[eff_words] = ZERO
            else:
                # OOV words --> write to memory
                c.word_indices[eff_words] = ZERO

                encoded_ngrams = compute_ngrams_bytes(token, c.min_n, c.max_n)
                hashes = [ft_hash_bytes(n) % c.bucket for n in encoded_ngrams]

                c.subwords_idx_len[eff_words] = <uINT_t>min(len(encoded_ngrams), MAX_NGRAMS)
                for i, h in enumerate(hashes[:MAX_NGRAMS]):
                    c.subwords_idx[eff_words + i] = <uINT_t>h
            
            eff_words += ONE

            if eff_words == MAX_WORDS:
                break
                
        eff_sents += 1
        c.sentence_boundary[eff_sents] = eff_words

        if eff_words == MAX_WORDS:
            break   

    return eff_sents, eff_words

cdef void compute_base_sentence_averages(BaseSentenceVecsConfig *c, uINT_t num_sentences) nogil:
    cdef:
        # TODO: Make the code less verbose by substituting word_vectors by c.word_vectors
        int size = c.size

        uINT_t sent_idx
        uINT_t sent_start
        uINT_t sent_end 
        uINT_t sent_row

        uINT_t i
        uINT_t word_idx
        uINT_t word_row

        uINT_t *word_ind = c.word_indices
        uINT_t *sent_adr = c.sent_adresses

        REAL_t sent_len
        REAL_t inv_count

        REAL_t *word_vectors = c.word_vectors
        REAL_t *word_weights = c.word_weights
        REAL_t *sent_vectors = c.sentence_vectors

    for sent_idx in range(num_sentences):
        sent_start = c.sentence_boundary[sent_idx]
        sent_end = c.sentence_boundary[sent_idx + 1]
        sent_len = ZEROF

        for i in range(sent_start, sent_end):
            sent_len += ONEF
            sent_row = sent_adr[i] * size
            word_row = word_ind[i] * size
            word_idx = word_ind[i]

            saxpy(&size, &word_weights[word_idx], &word_vectors[word_row], &ONE, &sent_vectors[sent_row], &ONE)

        if sent_len > ZEROF:
            inv_count = ONEF / sent_len
            sscal(&size, &inv_count, &sent_vectors[sent_row], &ONE)

cdef void compute_ft_sentence_averages(FTSentenceVecsConfig *c, uINT_t num_sentences) nogil:
    cdef:
        int size = c.size

        uINT_t sent_idx
        uINT_t sent_start
        uINT_t sent_end 
        uINT_t sent_row
        uINT_t ngram_row
        uINT_t ngrams

        uINT_t i, j
        uINT_t word_idx
        uINT_t word_row

        uINT_t *word_ind = c.word_indices
        uINT_t *sent_adr = c.sent_adresses

        uINT_t *ngram_len = c.subwords_idx_len
        uINT_t *ngram_ind = c.subwords_idx

        REAL_t sent_len
        REAL_t inv_count, inv_ngram
        REAL_t oov_weight = c.oov_weight

        REAL_t *mem = c.mem
        REAL_t *word_vectors = c.word_vectors
        REAL_t *ngram_vectors = c.ngram_vectors
        REAL_t *word_weights = c.word_weights

        REAL_t *sent_vectors = c.sentence_vectors


    memset(mem, 0, size * cython.sizeof(REAL_t))

    for sent_idx in range(num_sentences):
        sent_start = c.sentence_boundary[sent_idx]
        sent_end = c.sentence_boundary[sent_idx + 1]
        sent_len = ZEROF

        for i in range(sent_start, sent_end):
            sent_len += ONEF
            sent_row = sent_adr[i] * size

            word_idx = word_ind[i]
            ngrams = ngram_len[i]

            if ngrams == 0:
                word_row = word_ind[i] * size
                saxpy(&size, &word_weights[word_idx], &word_vectors[word_row], &ONE, &sent_vectors[sent_row], &ONE)
            else:
                for j in range(ngrams):
                    ngram_row = ngram_ind[i+j] * size
                    saxpy(&size, &ONEF, &ngram_vectors[ngram_row], &ONE, mem, &ONE)

                inv_ngram = ONEF / <REAL_t>ngrams
                saxpy(&size, &inv_ngram, mem, &ONE, &sent_vectors[sent_row], &ONE)
                memset(mem, 0, size * cython.sizeof(REAL_t))

        if sent_len > ZEROF:
            inv_count = ONEF / sent_len
            sscal(&size, &inv_count, &sent_vectors[sent_row], &ONE)

def train_average_cy(model, indexed_sentences, target, memory):
    """Training on a sequence of sentences and update the target ndarray.

    Called internally from :meth:`~fse.models.average.Average._do_train_job`.

    Parameters
    ----------
    model : :class:`~fse.models.base_s2v.BaseSentence2VecModel`
        The BaseSentence2VecModel model instance.
    indexed_sentences : iterable of IndexedSentence
        The sentences used to train the model.
    target : ndarray
        The target ndarray. We use the index from indexed_sentences
        to write into the corresponding row of target.

    Returns
    -------
    int, int
        Number of effective sentences (non-zero) and effective words in the vocabulary used 
        during training the sentence embedding.
    """

    cdef uINT_t eff_sentences = 0
    cdef uINT_t eff_words = 0
    cdef BaseSentenceVecsConfig w2v
    cdef FTSentenceVecsConfig ft

    if not model.is_ft:
        init_base_s2v_config(&w2v, model, target)

        eff_sentences, eff_words = populate_base_s2v_config(&w2v, model.wv.vocab, indexed_sentences)

        with nogil:
            compute_base_sentence_averages(&w2v, eff_sentences)
    else:        
        init_ft_s2v_config(&ft, model, target, memory)

        eff_sentences, eff_words = populate_ft_s2v_config(&ft, model.wv.vocab, indexed_sentences)

        with nogil:
            compute_ft_sentence_averages(&ft, eff_sentences) 
    
    return eff_sentences, eff_words

def init():
    return 1

MAX_WORDS_IN_BATCH = MAX_WORDS
MAX_NGRAMS_IN_BATCH = MAX_NGRAMS
FAST_VERSION = init()