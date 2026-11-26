<template>
  <div dir="auto">
    <div
      class="flex justify-between items-end w-full mb-3.5 md:mb-4"
      :class="{ 'mb-2': !field.description }"
    >
      <label
        v-if="showFieldNames"
        class="label text-xl sm:text-2xl py-0 field-name-label"
      >
        <MarkdownContent
          v-if="field.title"
          :string="field.title"
        />
        <template v-else>
          {{ field.name || t('initials') }}
        </template>
      </label>
      <div class="space-x-2 flex flex-none">
        <span
          v-if="isDrawInitials"
          class="md:tooltip"
          :data-tip="t('type_initial')"
        >
          <button
            id="type_text_button"
            type="button"
            :aria-label="t('type_initial')"
            class="btn btn-outline font-medium btn-sm type-text-button"
            @click="toggleTextInput"
          >
            <IconTextSize
              :width="16"
              aria-hidden="true"
            />
            <span class="hidden sm:inline">
              {{ t('type') }}
            </span>
          </button>
        </span>
        <span
          v-else
          class="md:tooltip ml-2"
          :data-tip="t('draw_initials')"
        >
          <button
            id="type_text_button"
            type="button"
            :aria-label="t('draw_initials')"
            class="btn btn-outline font-medium btn-sm type-text-button"
            @click="toggleTextInput"
          >
            <IconSignature
              :width="16"
              aria-hidden="true"
            />
            <span class="hidden sm:inline">
              {{ t('draw') }}
            </span>
          </button>
        </span>
        <span
          class="md:tooltip"
          :data-tip="t('click_to_upload')"
        >
          <button
            type="button"
            :aria-label="t('click_to_upload')"
            class="btn btn-outline btn-sm font-medium inline-flex flex-nowrap upload-image-button"
            @click="$refs.uploadInput.click()"
          >
            <IconUpload
              :width="16"
              aria-hidden="true"
            />
            <input
              :key="uploadImageInputKey"
              ref="uploadInput"
              type="file"
              hidden
              accept="image/*"
              @change="drawImage"
            >
            <span class="hidden sm:inline">
              {{ t('upload') }}
            </span>
          </button>
        </span>
        <button
          v-if="modelValue || computedPreviousValue || computedPrefillData"
          type="button"
          class="btn font-medium btn-outline btn-sm clear-canvas-button"
          @click="remove"
        >
          <IconReload
            :width="16"
            aria-hidden="true"
          />
          {{ t('clear') }}
        </button>
        <button
          v-else
          type="button"
          class="btn font-medium btn-outline btn-sm clear-canvas-button"
          @click="clear"
        >
          <IconReload
            :width="16"
            aria-hidden="true"
          />
          {{ t('clear') }}
        </button>
        <button
          type="button"
          :title="t('minimize')"
          :aria-label="t('minimize')"
          class="py-1.5 inline md:hidden"
          @click="$emit('minimize')"
        >
          <IconArrowsDiagonalMinimize2
            :width="20"
            :height="20"
            aria-hidden="true"
          />
        </button>
      </div>
    </div>
    <div
      v-if="field.description"
      dir="auto"
      class="mb-3 px-1 field-description-text"
    >
      <MarkdownContent :string="field.description" />
    </div>
    <AppearsOn :field="field" />
    <input
      :value="modelValue || computedPreviousValue"
      type="hidden"
      :name="`values[${field.uuid}]`"
    >
    <img
      v-if="modelValue || computedPreviousValue || computedPrefillData"
      :src="previousValueUrl"
      :alt="field.name || t('initials')"
      class="mx-auto bg-white border border-base-300 rounded max-h-44"
    >
    <div class="relative">
      <div
        v-if="!isDrawInitials"
        class="absolute top-0 right-0 left-0 bottom-0"
      />
      <label
        v-if="!isDrawInitials && !modelValue && !computedPreviousValue && !computedPrefillData"
        for="initials_text_input"
        class="absolute top-0 right-0 left-0 bottom-0"
      />
      <canvas
        v-show="!modelValue && !computedPreviousValue && !computedPrefillData"
        ref="canvas"
        role="img"
        :aria-label="t('initials_drawing_area')"
        class="bg-white border border-base-300 rounded-2xl w-full draw-canvas"
        @touchstart.passive="lockSwipe"
        @touchend.passive="unlockSwipe"
        @touchcancel.passive="unlockSwipe"
      />
    </div>
    <p
      class="text-error text-sm mt-2 empty:hidden initials-error-message"
      role="alert"
    >{{ errorMessage }}</p>
    <input
      v-if="!isDrawInitials && !modelValue && !computedPreviousValue && !computedPrefillData"
      id="initials_text_input"
      ref="textInput"
      class="base-input !text-2xl w-full mt-6 text-center"
      :required="field.required && !isInitialsStarted"
      :aria-label="field.name || t('initials')"
      :placeholder="`${t('type_initial_here')}${field.required ? '...' : ' (' + t('optional') + ')'}`"
      type="text"
      @focus="$emit('focus')"
      @input="updateWrittenInitials"
    >
  </div>
</template>

<script>
import { cropCanvasAndExportToPNG } from './crop_canvas'
import { loadTypedSignatureFont, drawTypedText } from './typed_signature'
import { IconReload, IconTextSize, IconUpload, IconSignature, IconArrowsDiagonalMinimize2 } from '@tabler/icons-vue'
import SignaturePad from 'signature_pad'
import AppearsOn from './appears_on'
import MarkdownContent from './markdown_content'
import SignatureStep from './signature_step'

const scale = 3

export default {
  name: 'InitialsStep',
  components: {
    IconUpload,
    AppearsOn,
    IconReload,
    IconTextSize,
    IconSignature,
    MarkdownContent,
    IconArrowsDiagonalMinimize2
  },
  inject: ['baseUrl', 'fetchOptions', 't'],
  props: {
    field: {
      type: Object,
      required: true
    },
    submitter: {
      type: Object,
      required: true
    },
    dryRun: {
      type: Boolean,
      required: false,
      default: false
    },
    submitterSlug: {
      type: String,
      required: true
    },
    showFieldNames: {
      type: Boolean,
      required: false,
      default: true
    },
    attachmentsIndex: {
      type: Object,
      required: false,
      default: () => ({})
    },
    previousValue: {
      type: String,
      required: false,
      default: ''
    },
    prefillData: {
      type: Object,
      required: false,
      default: null
    },
    nativePlatform: {
      type: String,
      required: false,
      default: ''
    },
    modelValue: {
      type: String,
      required: false,
      default: ''
    }
  },
  emits: ['attached', 'update:model-value', 'start', 'minimize', 'focus'],
  data () {
    return {
      isInitialsStarted: false,
      isUsePreviousValue: true,
      isDrawInitials: false,
      errorMessage: '',
      uploadImageInputKey: Math.random().toString()
    }
  },
  computed: {
    computedPreviousValue () {
      if (this.isUsePreviousValue && this.field.required === true) {
        return this.previousValue
      } else {
        return null
      }
    },
    computedPrefillData () {
      if (this.isUsePreviousValue && this.field.required === true && !this.previousValue && !this.modelValue) {
        return this.prefillData
      } else {
        return null
      }
    },
    previousValueUrl () {
      if (this.computedPrefillData) {
        return this.computedPrefillData.url
      } else {
        return this.attachmentsIndex[this.modelValue || this.computedPreviousValue].url
      }
    }
  },
  created () {
    this.isInitialsStarted = !!(this.computedPreviousValue || this.computedPrefillData)
  },
  async mounted () {
    if (!this.isDrawInitials) {
      loadTypedSignatureFont(this.baseUrl)
    }

    this.$nextTick(() => {
      if (this.$refs.canvas) {
        this.$refs.canvas.width = this.$refs.canvas.parentNode.clientWidth * scale
        this.$refs.canvas.height = (this.$refs.canvas.parentNode.clientWidth / 4.5) * scale

        this.$refs.canvas.getContext('2d').scale(scale, scale)
      }
    })

    if (this.$refs.canvas) {
      this.pad = new SignaturePad(this.$refs.canvas)

      if (this.field.preferences?.color) {
        this.pad.penColor = this.field.preferences.color
      }

      this.pad.addEventListener('beginStroke', () => {
        this.isInitialsStarted = true
        this.errorMessage = ''

        this.$emit('start')
      })

      this.intersectionObserver = new IntersectionObserver((entries, observer) => {
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            this.$refs.canvas.width = this.$refs.canvas.parentNode.clientWidth * scale
            this.$refs.canvas.height = (this.$refs.canvas.parentNode.clientWidth / 4.5) * scale

            this.$refs.canvas.getContext('2d').scale(scale, scale)

            if (!this.isDrawInitials) {
              this.$nextTick(() => {
                if (this.$refs.textInput && this.field.required === true) {
                  this.initTextInitial()
                }
              })
            }

            this.intersectionObserver?.disconnect()
          }
        })
      })

      this.intersectionObserver.observe(this.$refs.canvas)
    }
  },
  beforeUnmount () {
    this.intersectionObserver?.disconnect()
  },
  methods: {
    lockSwipe: SignatureStep.methods.lockSwipe,
    unlockSwipe: SignatureStep.methods.unlockSwipe,
    drawOnCanvas: SignatureStep.methods.drawOnCanvas,
    showError: SignatureStep.methods.showError,
    showCanvasError: SignatureStep.methods.showCanvasError,
    drawImage (event) {
      this.remove()
      this.isInitialsStarted = true

      this.drawOnCanvas(event.target.files[0], this.$refs.canvas)

      this.uploadImageInputKey = Math.random().toString()
    },
    remove () {
      this.$emit('update:model-value', '')

      this.isUsePreviousValue = false
      this.isInitialsStarted = false
    },
    clear () {
      this.pad.clear()

      this.isInitialsStarted = false
      this.errorMessage = ''

      if (this.$refs.textInput) {
        this.$refs.textInput.value = ''
      }
    },
    updateWrittenInitials (e) {
      this.isInitialsStarted = !!e.target.value
      this.errorMessage = ''

      const canvas = this.$refs.canvas
      const width = canvas.width / scale
      const height = canvas.height / scale

      drawTypedText(canvas.getContext('2d'), e.target.value, {
        width,
        height,
        maxFontSize: Math.min(76, height * 0.62),
        color: this.field.preferences?.color || '#000000'
      })
    },
    toggleTextInput () {
      this.remove()
      this.clear()
      this.isDrawInitials = !this.isDrawInitials

      if (!this.isDrawInitials) {
        this.$nextTick(() => {
          if (this.$refs.textInput) {
            if (!this.submitter.name) {
              this.$refs.textInput.focus()
            }

            this.initTextInitial()

            this.$emit('start')
          }
        })
      }
    },
    async initTextInitial () {
      if (this.submitter.name) {
        const parts = this.submitter.name.trim().split(/\s+/)

        this.$refs.textInput.value = (parts.length > 1 ? [parts[0], parts[parts.length - 1]] : parts).map((part) => part[0]?.toUpperCase() || '').join('')
      }

      await loadTypedSignatureFont(this.baseUrl)

      if (this.$refs.textInput?.value) {
        this.updateWrittenInitials({ target: this.$refs.textInput })
      }
    },
    submitPrefillAttachment () {
      if (this.dryRun) {
        const attachment = { uuid: Math.random().toString(), url: this.prefillData.url }

        this.$emit('attached', attachment)
        this.$emit('update:model-value', attachment.uuid)

        return Promise.resolve(attachment)
      }

      const formData = new FormData()

      formData.append('prefill_token', this.prefillData.token)

      return fetch(this.baseUrl + `/s/${this.submitterSlug}/prefill_attachments`, {
        method: 'POST',
        headers: { ...this.fetchOptions.headers },
        body: formData
      }).then(async (resp) => {
        if (!resp.ok) {
          const data = await resp.json()

          return Promise.reject(new Error(data.error))
        }

        const attachment = await resp.json()

        this.$emit('attached', attachment)
        this.$emit('update:model-value', attachment.uuid)

        return attachment
      }).catch((error) => {
        this.remove()

        return Promise.reject(error)
      })
    },
    async submit () {
      if (this.computedPrefillData) {
        return this.submitPrefillAttachment()
      }

      if (this.modelValue || this.computedPreviousValue) {
        if (this.computedPreviousValue) {
          this.$emit('update:model-value', this.computedPreviousValue)
        }

        return Promise.resolve({})
      }

      return new Promise((resolve, reject) => {
        cropCanvasAndExportToPNG(this.$refs.canvas, { errorOnTooSmall: true }).then(async (blob) => {
          const file = new File([blob], 'initials.png', { type: 'image/png' })

          if (this.dryRun) {
            const reader = new FileReader()

            reader.readAsDataURL(file)

            reader.onloadend = () => {
              const attachment = { url: reader.result, uuid: Math.random().toString() }

              this.$emit('attached', attachment)
              this.$emit('update:model-value', attachment.uuid)

              resolve(attachment)
            }
          } else {
            const formData = new FormData()

            formData.append('file', file)
            formData.append('submitter_slug', this.submitterSlug)
            formData.append('name', 'attachments')
            formData.append('type', 'initials')

            return fetch(this.baseUrl + `/s/${this.submitterSlug}/upload`, {
              method: 'POST',
              headers: { ...this.fetchOptions.headers },
              body: formData
            }).then((resp) => {
              if (resp.status === 404) {
                return fetch(this.baseUrl + '/api/attachments', {
                  method: 'POST',
                  headers: { ...this.fetchOptions.headers },
                  body: formData
                })
              } else {
                return resp
              }
            }).then(async (resp) => {
              if (resp.status === 422 || resp.status === 500) {
                const data = await resp.json()

                return Promise.reject(new Error(data.error))
              }

              const attachment = await resp.json()

              this.$emit('attached', attachment)
              this.$emit('update:model-value', attachment.uuid)

              return resolve(attachment)
            })
          }
        }).catch((error) => {
          if (this.field.required === true) {
            this.showCanvasError()

            return reject(error)
          } else {
            return resolve({})
          }
        })
      })
    }
  }
}
</script>
