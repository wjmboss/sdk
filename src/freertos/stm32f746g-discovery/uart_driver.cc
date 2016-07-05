// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/freertos/stm32f746g-discovery/uart_driver.h"

#include <stdlib.h>

#include <stm32f7xx_hal.h>

#include "src/freertos/device_manager_api.h"
#include "src/shared/atomic.h"
#include "src/shared/utils.h"
#include "src/shared/platform.h"
#include "src/vm/hash_map.h"

// Reference to the instance in the code generated by STM32CubeMX.
extern UART_HandleTypeDef huart1;

// Bits set from the interrupt handler.
const int kReceivedBit = 1 << 0;
const int kTransmittedBit = 1 << 1;
const int kErrorBit = 1 << 3;

const int kRxBufferSize = 511;
const int kTxBufferSize = 511;

static UartDriverImpl *uart1;

UartDriverImpl::UartDriverImpl()
  : error_(0),
    read_buffer_(new CircularBuffer(kRxBufferSize)),
    write_buffer_(new CircularBuffer(kTxBufferSize)),
    uart_(&huart1),
    device_id_(kIllegalDeviceId),
    tx_mutex_(dartino::Platform::CreateMutex()),
    tx_pending_(false) {}

static void UartTask(const void *arg) {
  const_cast<UartDriverImpl*>(
      reinterpret_cast<const UartDriverImpl*>(arg))->Task();
}

void UartDriverImpl::Initialize(uintptr_t device_id) {
  uart1 = this;
  ASSERT(device_id_ == kIllegalDeviceId);
  ASSERT(device_id != kIllegalDeviceId);
  device_id_ = device_id;
  osThreadDef(UART_TASK, UartTask, osPriorityHigh, 0, 128);
  signalThread_ =
      osThreadCreate(osThread(UART_TASK), reinterpret_cast<void*>(this));
  // Start receiving.

  // Enable the UART Parity Error Interrupt.
  __HAL_UART_ENABLE_IT(uart_, UART_IT_PE);

  // Enable the UART Frame, Noise and Overrun Error Interrupts.
  __HAL_UART_ENABLE_IT(uart_, UART_IT_ERR);

  // Enable the UART Data Register not empty Interrupt.
  __HAL_UART_ENABLE_IT(uart_, UART_IT_RXNE);

  // Disable the transmission complete interrupt as we are not using it.
  __HAL_UART_DISABLE_IT(uart_, UART_IT_TC);

  // TODO(sigurdm): Generalize when we support multiple UARTs. For
  // certain sleep modes this will be required to ensure all data is
  // send on the UART.
  HAL_NVIC_EnableIRQ(USART1_IRQn);
}

void UartDriverImpl::DeInitialize() {
  FATAL("NOT IMPLEMENTED");
}

size_t UartDriverImpl::Read(uint8_t* buffer, size_t count) {
  dartino::ScopedLock lock(tx_mutex_);
  int c = read_buffer_->Read(buffer, count);
  if (read_buffer_->IsEmpty()) {
    DeviceManagerClearFlags(device_id_, kReceivedBit);
  }
  return c;
}

size_t UartDriverImpl::Write(
    const uint8_t* buffer, size_t offset, size_t count) {
  dartino::ScopedLock lock(tx_mutex_);
  size_t written_count =
      write_buffer_->Write(buffer + offset, count);
  if (written_count > 0) {
    EnsureTransmission();
  }
  return written_count;
}

uint32_t UartDriverImpl::GetError() {
  DeviceManagerClearFlags(device_id_, kErrorBit);
  return error_;
}

void UartDriverImpl::Task() {
  // Process notifications from the interrupt handlers.
  for (;;) {
    // Wait for a signal.
    osEvent event = osSignalWait(0x0000FFFF, osWaitForever);
    if (event.status == osEventSignal) {
      dartino::ScopedLock lock(tx_mutex_);
      uint32_t flags = event.value.signals;
      if ((flags & kTransmittedBit) != 0) {
        EnsureTransmission();
      }
      // This will send a message on the event handler,
      // if there currently is an eligible listener.
      DeviceManagerSetFlags(device_id_, flags);
    }
  }
}

void UartDriverImpl::EnsureTransmission() {
  if (!tx_pending_) {
    tx_length_ = write_buffer_->Read(tx_data_, kTxBlockSize);

    if (tx_length_ > 0) {
      tx_progress_ = 0;
      tx_pending_ = true;
      __HAL_UART_ENABLE_IT(uart_, UART_IT_TXE);
    }
  } else {
    if (write_buffer_->IsFull()) {
      DeviceManagerClearFlags(device_id_, kTransmittedBit);
    }
  }
}

void UartDriverImpl::InterruptHandler() {
  uint32_t flags = 0;

  if ((__HAL_UART_GET_IT(uart_, UART_IT_PE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_PE) != RESET)) {
    // Parity error
    __HAL_UART_CLEAR_PEFLAG(uart_);
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_PE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_FE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_ERR) != RESET)) {
    // Frame error
    __HAL_UART_CLEAR_FEFLAG(uart_);
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_FE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_NE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_ERR) != RESET)) {
      __HAL_UART_CLEAR_NEFLAG(uart_);
    // Noise error
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_NE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_ORE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_ERR) != RESET)) {
    __HAL_UART_CLEAR_OREFLAG(uart_);
    // Overrun
    flags |= kErrorBit;
    error_ |= HAL_UART_ERROR_ORE;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_RXNE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_RXNE) != RESET)) {
    // Incoming character
    uint8_t byte = (uint8_t)(uart_->Instance->RDR & 0xff);
    if (read_buffer_->Write(&byte, 1) != 1) {
      // Buffer overflow. Ignored.
    }

    // Clear RXNE interrupt flag. Now the UART can receive another byte.
    __HAL_UART_SEND_REQ(uart_, UART_RXDATA_FLUSH_REQUEST);
    flags |= kReceivedBit;
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_TXE) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_TXE) != RESET)) {
    // Transmit data empty, write next char.
    if (tx_progress_ < tx_length_) {
      uart_->Instance->TDR = tx_data_[tx_progress_++];
    } else {
      // No more data. Disable the UART Transmit Data Register Empty Interrupt.
      __HAL_UART_DISABLE_IT(uart_, UART_IT_TXE);

      flags |= kTransmittedBit;
      tx_pending_ = false;
    }
  }

  if ((__HAL_UART_GET_IT(uart_, UART_IT_TC) != RESET) &&
      (__HAL_UART_GET_IT_SOURCE(uart_, UART_IT_TC) != RESET)) {
    // Transmission complete. Currently this is not handled.
    UNREACHABLE();
  }

  // Send a signal to the listening thread.
  if (flags != 0) {
    uint32_t result = osSignalSet(signalThread_, flags);
    ASSERT(result == osOK);
  }
}

extern "C" void USART1_IRQHandler(void) {
  uart1->InterruptHandler();
}

static void Initialize(UartDriver* driver) {
  UartDriverImpl* uart = new UartDriverImpl();
  driver->context = reinterpret_cast<uintptr_t>(uart);
  uart->Initialize(driver->device_id);
}

static void DeInitialize(UartDriver* driver) {
  UartDriverImpl* uart = reinterpret_cast<UartDriverImpl*>(driver->context);
  uart->DeInitialize();
  delete uart;
  driver->context = 0;
}

static size_t Read(UartDriver* driver, uint8_t* buffer, size_t count) {
  UartDriverImpl* uart = reinterpret_cast<UartDriverImpl*>(driver->context);
  return uart->Read(buffer, count);
}

static size_t Write(UartDriver* driver,
                    const uint8_t* buffer, size_t offset, size_t count) {
  UartDriverImpl* uart = reinterpret_cast<UartDriverImpl*>(driver->context);
  return uart->Write(buffer, offset, count);
}

static uint32_t GetError(UartDriver* driver) {
  UartDriverImpl* uart = reinterpret_cast<UartDriverImpl*>(driver->context);
  return uart->GetError();
}

extern "C" void FillUartDriver(UartDriver* driver) {
  driver->context = 0;
  driver->device_id = kIllegalDeviceId;
  driver->Initialize = Initialize;
  driver->DeInitialize = DeInitialize;
  driver->Read = Read;
  driver->Write = Write;
  driver->GetError = GetError;
}
